#!/usr/bin/env python3
"""Unit tests for the release-first private provider helper.

These tests stay unprivileged and exercise parser/admission contracts.  Linux
ownership, ACL, no-follow and container readability proof belongs to the
filesystem/runtime harness.
"""

from __future__ import annotations

import contextlib
import io
import importlib.util
import json
import os
import pathlib
import stat
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_vps_provider_credential", ROOT / "test-vps-provider-credential.py"
)
assert SPEC is not None and SPEC.loader is not None
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)


def inspection(enabled: bool = True) -> dict:
    env = [
        f"APP_PUSH_PROVIDER_ENABLED={'true' if enabled else 'false'}",
        "APP_PUSH_DISCOVERY_ENABLED=false",
        "APP_PUSH_DISPATCH_ENABLED=false",
        "APP_PUSH_DIAGNOSTIC_ENABLED=false",
        "APP_PUSH_MAINTENANCE_ENABLED=false",
        "APP_PUSH_PROJECT_ID=meeting-1d258",
    ]
    if enabled:
        env.append(f"APP_PUSH_CREDENTIALS_FILE={helper.CONTAINER_CREDENTIAL_PATH}")
    mounts = [
        {"Type": "volume", "Destination": "/data/uploads"},
        {"Type": "tmpfs", "Destination": "/tmp"},
    ]
    if enabled:
        mounts.append(
            {
                "Type": "bind",
                "Source": helper.HOST_CREDENTIAL_PATH,
                "Destination": helper.CONTAINER_CREDENTIAL_PATH,
                "RW": False,
            }
        )
    return {"Config": {"Env": env}, "Mounts": mounts}


def finalization_witness(enabled: bool = False) -> dict:
    empty_file = {
        "device": 1,
        "inode": 2,
        "uid": 0,
        "gid": 0,
        "mode": 0o600,
        "size": 4,
        "mtimeNs": 5,
        "ctimeNs": 6,
        "links": 1,
        "sha256": "a" * 64,
    }
    value = {
        "schema": helper.FINALIZATION_SCHEMA,
        "outcome": "committed",
        "runKey": "31885558214-1",
        "stateKind": "final-deploy",
        "ownedRun": "31885558214-1-final-deploy",
        "rootId": "test-root",
        "originDigest": "b" * 64,
        "incidentId": "c" * 32,
        "operationEpoch": 1,
        "evidenceDigest": "d" * 64,
        "commitWitnessDigest": "e" * 64,
        "containerId": "f" * 64,
        "configHash": "1" * 64,
        "imageId": "sha256:" + "2" * 64,
        "revision": "3" * 40,
        "version": "1.2.3",
        "repositoryDigest": "4" * 64,
        "platformImageId": "2" * 64,
        "providerEnabled": enabled,
        "durableDisposition": "created" if enabled else "none",
        "effectiveProviderDigest": "5" * 64,
        "startAttemptId": "c" * 32 + ":1",
        "config": [
            {"name": name, "identity": dict(empty_file, inode=index)}
            for index, name in enumerate(
                (
                    "config.env.target",
                    "config.env.target.identity",
                    "config.base-compose.yml",
                    "config.base-compose.yml.identity",
                ),
                start=10,
            )
        ],
        "transaction": None,
        "durableCredential": None,
        "terminal": {
            "schemaVersion": 1,
            "runKey": "31885558214-1",
            "outcome": "committed",
            "providerEnabled": enabled,
        },
        "pointer": {
            "schemaVersion": 1,
            "runKey": "31885558214-1",
            "phase": "finalizing",
            "providerEnabled": enabled,
            "durableDisposition": "created" if enabled else "none",
        },
    }
    if enabled:
        entries = []
        for index, name in enumerate(("identity.json", "snapshot", "publication"), start=20):
            links = 2 if name == "publication" else 1
            mode = 0o440 if name == "publication" else 0o600
            gid = 10001 if name == "publication" else 0
            entries.append(
                {
                    "name": name,
                    "identity": dict(
                        empty_file,
                        inode=index,
                        gid=gid,
                        mode=mode,
                        links=links,
                    ),
                    "quarantineName": (
                        f'.provider-cleanup-31885558214-1-{name.replace(".", "-")}'
                    ),
                    "linkProgression": [2, 1] if name == "publication" else [1],
                }
            )
        value["transaction"] = {
            "parent": {
                "device": 1,
                "inode": 30,
                "uid": 0,
                "gid": 0,
                "mode": 0o700,
                "links": 3,
            },
            "directory": {
                "device": 1,
                "inode": 31,
                "uid": 0,
                "gid": 0,
                "mode": 0o700,
                "links": 2,
            },
            "entries": entries,
        }
        value["durableCredential"] = dict(
            empty_file,
            inode=32,
            gid=10001,
            mode=0o440,
            links=2,
        )
    return value


def live_context(phase: str = "VERIFYING") -> tuple:
    module = helper._timepad_state_module()
    image = {
        "repositoryDigest": "1" * 64, "platformImageId": "2" * 64,
        "revision": "3" * 40, "version": "1.2.3",
        "migrationInventoryDigest": "4" * 64, "migrationResources": ["migration:fixture"],
        "beforeSchema": "5" * 64, "afterSchema": "6" * 64,
        "guardEvidence": "7" * 64, "dependencyPolicy": "resolved",
        "dependencyFloor": "8" * 64, "recoveryEvidence": "9" * 64,
        "retryExact": True, "unknownTransitionCovered": True,
    }
    predecessor = dict(image, platformImageId="a" * 64, revision="b" * 40, version="1.2.2")
    contract = {
        "schema": module.CONTRACT_SCHEMA, "formatVersion": 1,
        "controller": module.CONTROLLER, "active": True, "rootId": "test-root",
        "initialDomain": [],
        "images": [
            {"id": "target", "domain": "new-schema", "tuple": image},
            {"id": "previous", "domain": "new-schema", "tuple": predecessor},
        ],
        "transitions": [{
            "id": "first-timepad", "targetId": "target",
            "beforeSchema": image["beforeSchema"], "afterSchema": image["afterSchema"],
            "compatiblePredecessors": ["previous"],
        }],
    }
    admission = module.admit(
        contract, root_id="test-root", target_id="target", predecessor_id="previous",
        transition_id="first-timepad", target_tuple=image, predecessor_tuple=predecessor,
    )
    current = module.new_prepared_state(
        module.new_ready_state("c" * 64), operation="deploy", run_id="31885558214-1",
        incident_id="d" * 32, admission=admission, target=contract["images"][0],
        predecessor=contract["images"][1], transition_id="first-timepad",
        owned_run="31885558214-1-final-deploy", tooling_digest="e" * 64,
        predecessor_container_id="f" * 64,
        prepared_proof_digest="9" * 64,
    )
    if phase != "PREPARED":
        current.update(
            phase=phase, containerId="f" * 64, configHash="0" * 64,
            latestAttemptId=current["incidentId"] + ":1",
        )
        # Synthetic history for read-only adapter tests, not evidence that a
        # real supervisor lease may be superseded.
        current["runtimeRequest"] = {
            "nonce": "a" * 32, "sequence": 1, "executionAttempt": "b" * 32,
            "operation": "start", "containerId": current["containerId"],
            "imageId": image["platformImageId"], "configHash": current["configHash"],
            "childAttemptId": None, "lifecycle": "completed",
            "responseId": current["containerId"], "completionDigest": "c" * 64,
        }
    if phase in {"COMMITTING", "COMMITTED"}:
        current.update(
            commitWitnessDigest="1" * 64, providerFinalizationDigest="2" * 64,
            commitSubstep="provider-cleanup",
        )
    if phase == "COMMITTED":
        current.update(terminalReceipt="3" * 64, commitSubstep="policy-restored")
    origin = {"rootId": "test-root", "originDigest": current["originDigest"]}
    auth = {
        "schema": module.RECOVERY_AUTH_SCHEMA, "rootId": "test-root",
        "originDigest": current["originDigest"], "originalOperation": "deploy",
        "runId": current["runId"], "operationEpoch": current["operationEpoch"],
        "incidentId": current["incidentId"], "evidenceDigest": current["evidenceDigest"],
        "targetId": "target", "revision": image["revision"], "version": image["version"],
        "repositoryDigest": image["repositoryDigest"],
        "platformImageId": image["platformImageId"], "action": "retry-exact-candidate",
    }
    observed = inspection(False)
    observed.update(
        Id="f" * 64, Image="sha256:" + image["platformImageId"],
        HostConfig={"RestartPolicy": {"Name": "no"}},
        State={
            "Running": True, "Paused": False, "Restarting": False, "Dead": False,
            "Health": {"Status": "healthy"},
        },
    )
    observed["Config"].update(User="10001:10001", Labels={
        "com.docker.compose.project": "meet-production",
        "com.docker.compose.service": "backend",
        "com.docker.compose.config-hash": "0" * 64,
        "org.opencontainers.image.revision": image["revision"],
        "org.opencontainers.image.version": image["version"],
        "org.opencontainers.image.source": "https://github.com/NickolayMamonov/meet-backend-v3",
    })
    if phase == "PREPARED":
        observed["Image"] = "sha256:" + predecessor["platformImageId"]
        observed["Config"]["Labels"].update({
            "org.opencontainers.image.revision": predecessor["revision"],
            "org.opencontainers.image.version": predecessor["version"],
        })
        observed["HostConfig"]["RestartPolicy"]["Name"] = "unless-stopped"
    if phase == "COMMITTED":
        observed["HostConfig"]["RestartPolicy"]["Name"] = "unless-stopped"
    envelope = {
        "schema": helper.LIVE_RESUME_SCHEMA, "authorization": auth,
        "inspection": [observed], "stage": "admission",
    }
    if phase == "PREPARED":
        envelope.update(
            imageInspection=[{
                "Id": "sha256:" + image["platformImageId"],
                "Config": dict(observed["Config"], Labels=dict(
                    observed["Config"]["Labels"],
                    **{
                        "org.opencontainers.image.revision": image["revision"],
                        "org.opencontainers.image.version": image["version"],
                    },
                )),
            }],
            targetConfiguration={"services": {"backend": {
                "image": "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
                + image["repositoryDigest"],
            }}},
            backendInventory=[current["predecessorContainerId"]],
        )
    return module, contract, origin, current, envelope


class RuntimeRequestProofTests(unittest.TestCase):
    def context(self):
        context = live_context()
        current, observed = context[3], context[4]["inspection"][0]
        current["runtimeRequest"].update(lifecycle="acknowledged", completionDigest=None)
        return current, observed

    def test_explicit_acknowledgment_and_exact_effect_are_both_required(self):
        for operation, running, policy, substep in (
            ("start", True, "no", None),
            ("stop", False, "no", None),
            ("suppress", True, "no", None),
            ("restore-policy", True, "unless-stopped", "terminal-policy-intent"),
        ):
            current, observed = self.context()
            current["runtimeRequest"]["operation"] = operation
            if substep is not None:
                current.update(phase="COMMITTING", commitSubstep=substep)
            observed["State"]["Running"] = running
            observed["HostConfig"]["RestartPolicy"]["Name"] = policy
            with self.subTest(operation=operation):
                proof = helper._runtime_request_proof(current, observed)
                self.assertEqual("a" * 32, proof["requestNonce"])
                self.assertRegex(proof["completionDigest"], r"^[a-f0-9]{64}$")
                self.assertEqual(proof, helper._runtime_request_proof(current, observed))
                current["runtimeRequest"].update(
                    lifecycle="intent", responseId=None, completionDigest=None,
                )
                with self.assertRaises(helper.ProviderError):
                    helper._runtime_request_proof(current, observed)

    def test_unknown_timeout_completed_replay_and_identity_mismatch_refuse(self):
        for lifecycle in ("intent", "completed"):
            current, observed = self.context()
            current["runtimeRequest"].update(
                lifecycle=lifecycle,
                responseId=None if lifecycle == "intent" else current["containerId"],
                completionDigest="c" * 64 if lifecycle == "completed" else None,
            )
            with self.subTest(lifecycle=lifecycle), self.assertRaises(helper.ProviderError):
                helper._runtime_request_proof(current, observed)
        for path, value in (
            (("Id",), "e" * 64), (("Image",), "sha256:" + "e" * 64),
            (("Config", "Labels", "com.docker.compose.config-hash"), "e" * 64),
            (("State", "Running"), False),
            (("HostConfig", "RestartPolicy", "Name"), "unless-stopped"),
        ):
            current, observed = self.context()
            target = observed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(helper.ProviderError):
                helper._runtime_request_proof(current, observed)

    def test_nonce_changes_digest_and_owned_group_requires_positive_quiescence(self):
        current, observed = self.context()
        first = helper._runtime_request_proof(current, observed)
        current["runtimeRequest"]["nonce"] = "e" * 32
        self.assertNotEqual(first, helper._runtime_request_proof(current, observed))
        module = helper._timepad_state_module()
        attempt = current["incidentId"] + ":1"
        current["runtimeRequest"]["childAttemptId"] = attempt
        current["ownedChild"] = {"attemptId": attempt}
        with mock.patch.object(module, "require_child_group_quiescent") as quiescent:
            helper._runtime_request_proof(current, observed)
            quiescent.assert_called_once_with(current["ownedChild"])
            quiescent.side_effect = module.GuardError("OWNED_CHILD_QUIESCENCE_UNCONFIRMED")
            with self.assertRaises(helper.ProviderError):
                helper._runtime_request_proof(current, observed)

    def test_matching_inventory_never_completes_unknown_request(self):
        context = live_context()
        context[3]["runtimeRequest"].update(
            lifecycle="intent", responseId=None, completionDigest=None,
        )
        with self.assertRaises(helper.ProviderError):
            LiveResumeTests().run_proof(context)

    def test_private_completion_adapter_rechecks_nonce_state_and_deadline_without_writes(self):
        module = helper._timepad_state_module()
        for fault in ("none", "wrong-nonce", "state-drift", "deadline"):
            current, observed = self.context()
            envelope = {
                "requestNonce": "e" * 32 if fault == "wrong-nonce" else "a" * 32,
                "inspection": [observed],
            }
            final = dict(current, reason="changed") if fault == "state-drift" else current
            with self.subTest(fault=fault), contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(helper, "_open_deploy_state_root", return_value=11))
                stack.enter_context(mock.patch.object(helper, "_lock_directory"))
                stack.enter_context(mock.patch.object(helper, "_timepad_current", side_effect=[
                    (module, {}, current), (module, {}, final),
                ]))
                stack.enter_context(mock.patch.object(helper.os, "open", return_value=12))
                stack.enter_context(mock.patch.object(helper.os, "close"))
                stack.enter_context(mock.patch.object(helper, "_validate_state_directory_fd"))
                stack.enter_context(mock.patch.object(helper, "_live_resume_config"))
                if fault == "deadline":
                    stack.enter_context(mock.patch.object(
                        helper, "_deadline_check", side_effect=helper.ProviderError("RECOVERY_REQUIRED"),
                    ))
                write = stack.enter_context(mock.patch.object(helper.os, "write"))
                unlink = stack.enter_context(mock.patch.object(helper.os, "unlink"))
                output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                def complete():
                    helper._runtime_request_completion(
                        current["runId"], "/state", "final-deploy", json.dumps(envelope).encode(), 9,
                    )
                if fault == "none":
                    complete()
                    self.assertEqual(
                        helper._runtime_request_proof(current, observed),
                        json.loads(output.getvalue()),
                    )
                else:
                    with self.assertRaises(helper.ProviderError):
                        complete()
                    self.assertEqual("", output.getvalue())
                write.assert_not_called()
                unlink.assert_not_called()


class LiveResumeTests(unittest.TestCase):
    def authority(self, context: tuple) -> tuple:
        module, contract, origin, current, envelope = context
        with mock.patch.object(module, "_read_input", return_value=json.dumps(contract).encode()):
            return helper._live_resume_authority(
                envelope, module=module, origin=origin, current=current,
                run_key="31885558214-1", state_kind="final-deploy",
            )

    def test_stale_lease_proof_requires_exact_complete_inventories_and_known_request(self):
        for lifecycle in ("completed", "acknowledged", "intent", None):
            context = live_context()
            current, envelope = context[3], context[4]
            if lifecycle is None:
                current["runtimeRequest"] = None
            else:
                current["runtimeRequest"].update(
                    lifecycle=lifecycle,
                    responseId=current["containerId"] if lifecycle != "intent" else None,
                    completionDigest="e" * 64 if lifecycle == "completed" else None,
                )
            evidence = {
                "inspection": envelope["inspection"],
                "backendInventory": [current["containerId"]],
                "composeInventory": [current["containerId"]],
            }
            for fault in ("none", "extra-global", "missing-compose", "foreign-runtime", "proof", "revoked"):
                value = json.loads(json.dumps(evidence))
                if fault == "extra-global":
                    value["backendInventory"].append("e" * 64)
                elif fault == "missing-compose":
                    value["composeInventory"] = []
                elif fault == "foreign-runtime":
                    value["inspection"][0]["Image"] = "sha256:" + "e" * 64
                check = mock.Mock()
                if fault == "revoked":
                    check.side_effect = helper.ProviderError("RECOVERY_REQUIRED")
                with self.subTest(lifecycle=lifecycle, fault=fault), mock.patch.object(
                    helper, "_validate_live_resume", return_value=(False, False, False, "retry-exact-candidate"),
                ) as proof, mock.patch.object(helper.os, "write") as write, \
                        mock.patch.object(helper.os, "unlink") as unlink:
                    if fault == "proof":
                        proof.side_effect = helper.ProviderError("RECOVERY_REQUIRED")

                    def validate():
                        return helper._recovery_lease_runtime_proof(
                            "/state", current, json.dumps(envelope["authorization"]).encode(),
                            json.dumps(value).encode(), 9, check,
                        )

                    if fault == "none" and lifecycle in {"completed", "acknowledged"}:
                        request = validate()
                        self.assertEqual("completed", request["lifecycle"])
                        self.assertEqual(current["runtimeRequest"]["nonce"], request["nonce"])
                        self.assertEqual(2, check.call_count)
                        proof.assert_called_once()
                        self.assertEqual(9, proof.call_args.args[-1])
                        self.assertEqual("runtime", json.loads(proof.call_args.args[-2])["stage"])
                    else:
                        with self.assertRaises(helper.ProviderError):
                            validate()
                    write.assert_not_called()
                    unlink.assert_not_called()
                    self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_live_marker_sequence_is_specific_to_the_persisted_schema_phase(self):
        allowed = {
            "PREPARED": {"prepared", "applying"},
            "CUTOVER_POSSIBLE": {"prepared", "applying", "verifying"},
            "ROLLING_BACK": {"prepared", "applying", "verifying", "rolling-back"},
            "VERIFYING": {"verifying"},
            "RECOVERY_REQUIRED": {"verifying"},
            "FORWARD_RECOVERING": {"verifying"},
        }
        for phase, permitted in allowed.items():
            for marker in ("prepared", "applying", "verifying", "rolling-back"):
                with self.subTest(phase=phase, marker=marker):
                    context = live_context(phase)
                    if marker in permitted:
                        self.run_proof(context, marker_phase=marker)
                    else:
                        with self.assertRaises(helper.ProviderError):
                            self.run_proof(context, marker_phase=marker)

    def run_proof(
        self, context: tuple, *, receipt_error: bool = False,
        transaction_error: bool = False, state_drift: bool = False,
        marker_phase: str | None = None,
        absence_envelope: dict | None = None,
    ) -> tuple:
        module, contract, origin, current, envelope = context
        stream = io.StringIO()
        marker = {
            "schemaVersion": 1, "runKey": current["runId"],
            "phase": marker_phase or (
                "prepared" if current["phase"] == "PREPARED" else "verifying"
            ),
            "providerEnabled": False, "durableDisposition": "none",
        }
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(module, "_read_input", return_value=json.dumps(contract).encode()))
            stack.enter_context(mock.patch.object(helper, "_open_deploy_state_root", return_value=11))
            stack.enter_context(mock.patch.object(helper, "_timepad_current", side_effect=[
                (module, origin, current),
                (module, origin, dict(current, operationEpoch=2)) if state_drift
                else (module, origin, current),
            ]))
            stack.enter_context(mock.patch.object(helper, "_lock_directory"))
            stack.enter_context(mock.patch.multiple(
                helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
            ))
            stack.enter_context(mock.patch.object(helper.os, "open", return_value=12))
            stack.enter_context(mock.patch.object(helper.os, "close"))
            stack.enter_context(mock.patch.object(helper, "_validate_state_directory_fd"))
            stack.enter_context(mock.patch.object(helper, "_iter_directory_fd_names", return_value=()))
            stack.enter_context(mock.patch.object(helper, "_open_optional_directory_reference", return_value=None))
            config = stack.enter_context(mock.patch.object(helper, "_live_resume_config"))
            stack.enter_context(mock.patch.object(
                helper, "_prepared_target", return_value=(
                    {"provider": {"providerEnabled": False, "durableDisposition": "none",
                                  "transaction": None}},
                    helper._effective_tuple(envelope["inspection"][0]),
                ),
            ))
            stack.enter_context(mock.patch.object(
                helper, "_prepared_transaction", return_value={
                    "providerEnabled": False, "durableDisposition": "none", "transaction": None,
                },
            ))
            stack.enter_context(mock.patch.object(helper, "_live_resume_predecessor"))
            transaction = stack.enter_context(mock.patch.object(
                helper, "_live_resume_transaction", return_value=marker,
                side_effect=helper.ProviderError("RECOVERY_REQUIRED") if transaction_error else None,
            ))
            receipt = stack.enter_context(mock.patch.object(
                helper, "_live_resume_receipt",
                side_effect=helper.ProviderError("RECOVERY_REQUIRED") if receipt_error else None,
            ))
            absence_receipt = stack.enter_context(mock.patch.object(
                helper, "_absence_receipt",
                side_effect=helper.ProviderError("RECOVERY_REQUIRED") if receipt_error else None,
            ))
            stack.enter_context(mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError))
            unlink = stack.enter_context(mock.patch.object(helper.os, "unlink"))
            replace = stack.enter_context(mock.patch.object(helper.os, "replace"))
            write = stack.enter_context(mock.patch.object(helper.os, "write"))
            fsync = stack.enter_context(mock.patch.object(helper.os, "fsync"))
            stack.enter_context(contextlib.redirect_stdout(stream))
            proof = helper._absence_resume if absence_envelope is not None else helper._live_resume
            proof(
                current["runId"], "/var/lib/meet-test-vps-deploy", "final-deploy",
                json.dumps(absence_envelope if absence_envelope is not None else envelope).encode(), 9,
            )
        unlink.assert_not_called()
        replace.assert_not_called()
        write.assert_not_called()
        fsync.assert_not_called()
        return json.loads(stream.getvalue()), config, transaction, (
            absence_receipt if absence_envelope is not None else receipt
        )

    def receipt_context(self, phase: str = "COMMITTED", enabled: bool = False) -> tuple:
        module, contract, origin, current, envelope = live_context(phase)
        observed = envelope["inspection"][0]
        if enabled:
            original_config = observed["Config"]
            observed.update(inspection(True))
            observed["Config"].update({
                "User": original_config["User"], "Labels": original_config["Labels"],
            })
        commit = {
            "schema": "meet-backend/test-vps-timepad-commit-witness/v1",
            "operationEpoch": current["operationEpoch"], "incidentId": current["incidentId"],
            "containerId": current["containerId"], "configHash": current["configHash"],
            "imageId": observed["Image"], "revision": current["target"]["tuple"]["revision"],
            "version": current["target"]["tuple"]["version"], "providerEnabled": enabled,
        }
        commit_data = json.dumps(commit, separators=(",", ":")).encode()
        witness = finalization_witness(enabled)
        for key in ("originDigest", "incidentId", "operationEpoch", "evidenceDigest",
                    "containerId", "configHash"):
            witness[key] = current[key]
        target = current["target"]["tuple"]
        witness.update(
            imageId=observed["Image"], revision=target["revision"], version=target["version"],
            repositoryDigest=target["repositoryDigest"], platformImageId=target["platformImageId"],
            commitWitnessDigest=helper._finalization_digest(commit_data),
            startAttemptId=current["latestAttemptId"],
            effectiveProviderDigest=helper._finalization_digest(json.dumps(
                helper._effective_tuple(observed), sort_keys=True, separators=(",", ":"),
            ).encode()),
        )
        data = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
        current.update(
            commitWitnessDigest=helper._finalization_digest(commit_data),
            providerFinalizationDigest=helper._finalization_digest(data),
        )
        result = json.dumps({
            "schemaVersion": 1, "providerEnabled": enabled,
            "credentialMountPresent": enabled, "credentialMountReadOnly": enabled,
            "outcome": "committed",
        }, separators=(",", ":")).encode()
        current["terminalReceipt"] = helper._finalization_digest(result)
        return origin, current, observed, commit, commit_data, witness, data

    def validate_terminal_receipt(self, context: tuple) -> None:
        origin, current, observed, commit, commit_data, witness, data = context
        records = {entry["name"]: entry["identity"] for entry in witness["config"]}
        with (
            mock.patch.object(helper, "_read_finalization_witness", return_value=(witness, data)),
            mock.patch.object(helper, "_controller_commit_witness", return_value=(
                commit, commit_data, helper._finalization_digest(commit_data),
            )),
            mock.patch.object(helper, "_file_record", side_effect=lambda fd, name: records[name]),
            mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
            mock.patch.object(helper, "_validate_existing_finalization_terminal") as terminal,
            mock.patch.object(helper.os.path, "lexists", return_value=False),
            mock.patch.object(helper, "_read_existing") as read_credential,
            mock.patch.object(helper.os, "unlink") as unlink,
            mock.patch.object(helper.os, "write") as write,
            mock.patch.object(helper.os, "fsync") as fsync,
        ):
            helper._live_resume_receipt(11, 12, "/state", current, origin, observed)
        terminal.assert_called_once_with(12, witness)
        read_credential.assert_not_called()
        unlink.assert_not_called()
        write.assert_not_called()
        fsync.assert_not_called()

    def test_exact_authority_is_independently_readmitted(self) -> None:
        context = live_context()
        observed, stage = self.authority(context)
        self.assertEqual(context[4]["inspection"][0], observed)
        self.assertEqual("admission", stage)

    def test_every_wrong_selector_refuses(self) -> None:
        replacements = {
            "rootId": "wrong-root", "originDigest": "0" * 64,
            "originalOperation": "rollback-drill", "runId": "31885558214-2",
            "operationEpoch": 2, "incidentId": "0" * 32,
            "evidenceDigest": "0" * 64, "targetId": "wrong-target",
            "revision": "0" * 40, "version": "9.9.9",
            "repositoryDigest": "0" * 64, "platformImageId": "0" * 64,
            "action": "retry-other-candidate",
        }
        for field, value in replacements.items():
            context = live_context()
            context[4]["authorization"][field] = value
            with self.subTest(field=field), self.assertRaises(helper.ProviderError):
                self.authority(context)

    def test_envelope_keys_types_schema_stage_are_exact(self) -> None:
        for change in (
            {"extra": True}, {"schema": "wrong"}, {"stage": "status"},
            {"authorization": None}, {"inspection": None},
        ):
            context = live_context()
            context[4].update(change)
            with self.subTest(change=change), self.assertRaises(helper.ProviderError):
                self.authority(context)
        context = live_context()
        del context[4]["stage"]
        with self.assertRaises(helper.ProviderError):
            self.authority(context)

    def test_changed_contract_and_wrong_original_operation_refuse(self) -> None:
        for field, value in (("rootId", "other-root"), ("active", False)):
            context = live_context()
            context[1][field] = value
            with self.subTest(field=field), self.assertRaises(helper.ProviderError):
                self.authority(context)
        context = live_context()
        context[3]["operation"] = "rollback-drill"
        with self.assertRaises(helper.ProviderError):
            self.authority(context)

    def test_active_unknown_child_refuses_and_absent_group_is_rechecked(self) -> None:
        context = live_context("CUTOVER_POSSIBLE")
        module, _, _, current, _ = context
        child = {
            "pid": 101, "processGroup": 101,
            "bootId": "01234567-89ab-cdef-0123-456789abcdef",
            "startTicks": 1234, "commandDigest": "5" * 64,
            "attemptId": current["incidentId"] + ":1", "lifecycle": "released",
        }
        current.update(ownedChild=child, latestAttemptId=child["attemptId"])
        for reason in ("OWNED_CHILD_STILL_RUNNING", "OWNED_CHILD_UNVERIFIABLE"):
            with (
                self.subTest(reason=reason),
                mock.patch.object(
                    module, "require_child_group_quiescent",
                    side_effect=module.GuardError(reason),
                ),
                self.assertRaises(helper.ProviderError),
            ):
                self.authority(context)
        with mock.patch.object(module, "require_child_group_quiescent") as absent:
            self.authority(context)
        absent.assert_called_once_with(child)

    def test_prepared_does_not_accept_post_cutover_history(self) -> None:
        for key, value in (
            ("containerId", "a" * 64), ("configHash", "a" * 64),
            ("commitWitnessDigest", "a" * 64), ("providerFinalizationDigest", "a" * 64),
            ("commitSubstep", "provider-cleanup"), ("terminalReceipt", "a" * 64),
        ):
            context = live_context("PREPARED")
            context[3][key] = value
            with self.subTest(key=key), self.assertRaises(helper.ProviderError):
                self.authority(context)

    def test_quiescence_preflight_requires_child_and_positive_group_identity(self) -> None:
        context = live_context("CUTOVER_POSSIBLE")
        module, _, _, current, envelope = context
        envelope["stage"] = "quiescence"
        with self.assertRaises(helper.ProviderError):
            self.authority(context)
        current["ownedChild"] = {
            "pid": 101, "processGroup": 101,
            "bootId": "01234567-89ab-cdef-0123-456789abcdef",
            "startTicks": 1234, "commandDigest": "5" * 64,
            "attemptId": current["incidentId"] + ":1", "lifecycle": "released",
        }
        with (
            mock.patch.object(module, "owned_child_is_same_process", return_value=True),
            mock.patch.object(module, "require_child_group_quiescent") as absent,
        ):
            self.authority(context)
            result, _, transaction, receipt = self.run_proof(context)
            self.assertEqual("retry-exact-candidate", result["outcome"])
            transaction.assert_called_once()
            receipt.assert_not_called()
        absent.assert_not_called()
        with (
            mock.patch.object(module, "owned_child_is_same_process", return_value=False),
            mock.patch.object(module, "require_child_group_quiescent",
                              side_effect=module.GuardError("OWNED_CHILD_UNVERIFIABLE")),
            self.assertRaises(helper.ProviderError),
        ):
            self.authority(context)

    def test_exact_target_runtime_requires_image_container_hash_revision_version(self) -> None:
        for path, value in (
            (("Image",), "sha256:" + "a" * 64),
            (("Id",), "a" * 64),
            (("Config", "Labels", "com.docker.compose.config-hash"), "a" * 64),
            (("Config", "Labels", "org.opencontainers.image.revision"), "a" * 40),
            (("Config", "Labels", "org.opencontainers.image.version"), "9.9.9"),
            (("Config", "Labels", "com.docker.compose.service"), "db"),
            (("HostConfig", "RestartPolicy", "Name"), "always"),
        ):
            context = live_context()
            current, observed = context[3], context[4]["inspection"][0]
            target = observed
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(helper.ProviderError):
                helper._live_resume_runtime(observed, current, "runtime")

    def test_prepared_predecessor_is_admission_only_and_post_fence_must_be_stopped(self) -> None:
        context = live_context("PREPARED")
        observed, current = context[4]["inspection"][0], context[3]
        self.assertEqual((False, False), helper._live_resume_runtime(observed, current, "admission"))
        with self.assertRaises(helper.ProviderError):
            helper._live_resume_runtime(observed, current, "runtime")
        current["phase"] = "CUTOVER_POSSIBLE"
        with self.assertRaises(helper.ProviderError):
            helper._live_resume_runtime(observed, current, "admission")
        observed["State"]["Running"] = False
        observed["HostConfig"]["RestartPolicy"]["Name"] = "no"
        self.assertEqual((False, False), helper._live_resume_runtime(observed, current, "admission"))
        for container_id in (None, "a" * 64):
            current["predecessorContainerId"] = container_id
            with self.assertRaises(helper.ProviderError):
                helper._live_resume_runtime(observed, current, "admission")

    def test_policy_restoration_requires_persisted_phase_intent(self) -> None:
        context = live_context("COMMITTING")
        current, observed = context[3], context[4]["inspection"][0]
        observed["HostConfig"]["RestartPolicy"]["Name"] = "unless-stopped"
        with self.assertRaises(helper.ProviderError):
            helper._live_resume_runtime(observed, current, "runtime")
        current["commitSubstep"] = "terminal-policy-intent"
        self.assertEqual((True, True), helper._live_resume_runtime(observed, current, "runtime"))

    def test_healthy_verifying_finalizes_without_mutation_and_unhealthy_retries(self) -> None:
        context = live_context()
        value, config, transaction, receipt = self.run_proof(context)
        self.assertEqual("finalization-only", value["outcome"])
        config.assert_called_once()
        transaction.assert_called_once()
        receipt.assert_not_called()
        context[4]["inspection"][0]["State"]["Health"]["Status"] = "unhealthy"
        self.assertEqual("retry-exact-candidate", self.run_proof(context)[0]["outcome"])

    def test_missing_live_transaction_and_state_drift_refuse_before_output(self) -> None:
        with self.assertRaises(helper.ProviderError):
            self.run_proof(live_context(), transaction_error=True)
        with self.assertRaises(helper.ProviderError):
            self.run_proof(live_context(), state_drift=True)

    def test_prepared_and_each_recoverable_phase_require_intact_live_proof(self) -> None:
        for phase in (
            "PREPARED", "CUTOVER_POSSIBLE", "RECOVERY_REQUIRED",
            "FORWARD_RECOVERING", "ROLLING_BACK",
        ):
            with self.subTest(phase=phase):
                value, _, transaction, receipt = self.run_proof(live_context(phase))
                expected = "finalization-only" if phase in {
                    "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
                } else "retry-exact-candidate"
                self.assertEqual(expected, value["outcome"])
                transaction.assert_called_once()
                receipt.assert_not_called()
                context = live_context(phase)
                context[4]["inspection"][0]["State"]["Running"] = False
                self.assertEqual("retry-exact-candidate", self.run_proof(context)[0]["outcome"])
                with self.assertRaises(helper.ProviderError):
                    self.run_proof(context, transaction_error=True)

    def test_prepared_applying_admission_is_read_only_without_post_cutover_history(self) -> None:
        context = live_context("PREPARED")
        before = json.dumps(context[3], sort_keys=True)
        for phase in ("prepared", "applying"):
            with self.subTest(marker=phase):
                result, _, transaction, receipt = self.run_proof(
                    context, marker_phase=phase,
                )
                self.assertEqual("retry-exact-candidate", result["outcome"])
                transaction.assert_called_once()
                receipt.assert_not_called()
                self.assertEqual(before, json.dumps(context[3], sort_keys=True))
        for phase in ("preparing", "verifying", "rolling-back", "finalizing"):
            with self.subTest(marker=phase), self.assertRaises(helper.ProviderError):
                self.run_proof(context, marker_phase=phase)

    def test_absence_resume_is_read_only_and_refuses_inventory_authority_and_state_drift(self) -> None:
        context = live_context("COMMITTING")
        observed = context[4]["inspection"][0]
        envelope = dict(
            schema=helper.ABSENCE_RESUME_SCHEMA,
            authorization=context[4]["authorization"],
            imageInspection=[{"Id": observed["Image"], "Config": observed["Config"]}],
            targetConfiguration={"services": {"backend": {
                "image": "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
                + context[3]["target"]["tuple"]["repositoryDigest"],
                "environment": {},
            }}},
            backendInventory=[],
        )
        with mock.patch.object(helper, "_live_resume_runtime") as runtime:
            result, config, transaction, receipt = self.run_proof(
                context, absence_envelope=envelope,
            )
        self.assertEqual("retry-exact-candidate", result["outcome"])
        runtime.assert_not_called()
        config.assert_called_once()
        transaction.assert_not_called()
        receipt.assert_called_once()
        for key, value in (
            ("backendInventory", ["unknown"]),
            ("backendInventory", None),
            ("schema", helper.LIVE_RESUME_SCHEMA),
            ("inspection", []),
            ("authorization", dict(envelope["authorization"], operationEpoch=2)),
        ):
            changed = dict(envelope, **{key: value})
            with self.subTest(key=key), self.assertRaises(helper.ProviderError):
                self.run_proof(context, absence_envelope=changed)
        with self.assertRaises(helper.ProviderError):
            self.run_proof(context, absence_envelope=envelope, state_drift=True)
        with self.assertRaises(helper.ProviderError):
            self.run_proof(context, absence_envelope=envelope, receipt_error=True)
        with self.assertRaises(helper.ProviderError):
            helper._absence_resume(
                context[3]["runId"], "/state", "final-deploy", json.dumps(envelope).encode(), -1,
            )
        with contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(1, helper.main(["absence-resume"]))
        self.assertEqual("RECOVERY_REQUIRED\n", error.getvalue())

    def test_absence_tuple_resolves_image_defaults_without_runtime_or_health(self) -> None:
        context = live_context("COMMITTING")
        current, observed = context[3], context[4]["inspection"][0]
        image = {"Id": observed["Image"], "Config": observed["Config"]}
        configuration = {"services": {"backend": {
            "image": "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
            + current["target"]["tuple"]["repositoryDigest"],
            "environment": {},
        }}}
        expected = helper._effective_tuple(observed)
        with mock.patch.object(helper, "_live_resume_runtime") as runtime:
            self.assertEqual(expected, helper._absence_target_tuple(image, configuration, current))
        runtime.assert_not_called()
        for field, replacement in (
            ("image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "0" * 64),
            ("environment", {"APP_PUSH_PROVIDER_ENABLED": True}),
            ("environment", {"spring.application.json": "{}"}),
            ("command", ["--app.push.provider-enabled=true"]),
            ("volumes", [{"target": helper.CONTAINER_CREDENTIAL_PATH}]),
        ):
            changed = json.loads(json.dumps(configuration))
            changed["services"]["backend"][field] = replacement
            with self.subTest(field=field, replacement=replacement), self.assertRaises(helper.ProviderError):
                helper._absence_target_tuple(image, changed, current)
        for field, replacement in (
            ("Id", "sha256:" + "0" * 64),
            ("Config", dict(image["Config"], User="0")),
        ):
            changed = dict(image, **{field: replacement})
            with self.subTest(image=field), self.assertRaises(helper.ProviderError):
                helper._absence_target_tuple(changed, configuration, current)

    def test_absence_enabled_tuple_requires_fixed_read_only_no_create_mount(self) -> None:
        context = live_context("COMMITTING")
        current, observed = context[3], context[4]["inspection"][0]
        image = {"Id": observed["Image"], "Config": dict(
            observed["Config"], Env=inspection(True)["Config"]["Env"],
        )}
        mount = dict(
            type="bind", source=helper.HOST_CREDENTIAL_PATH,
            target=helper.CONTAINER_CREDENTIAL_PATH, read_only=True,
            bind={"create_host_path": False},
        )
        configuration = {"services": {"backend": {
            "image": "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
            + current["target"]["tuple"]["repositoryDigest"],
            "volumes": [mount],
        }}}
        self.assertEqual("true", helper._absence_target_tuple(
            image, configuration, current,
        )["APP_PUSH_PROVIDER_ENABLED"])
        for field, replacement in (
            ("source", "/unknown"), ("read_only", False),
            ("bind", "invalid"), ("bind", {"create_host_path": True}),
        ):
            changed = json.loads(json.dumps(configuration))
            changed["services"]["backend"]["volumes"][0][field] = replacement
            with self.subTest(field=field), self.assertRaises(helper.ProviderError):
                helper._absence_target_tuple(image, changed, current)

    def test_absence_receipt_requires_original_binding_and_preserves_witness(self) -> None:
        origin, current, observed, commit, commit_data, witness, data = self.receipt_context(
            "COMMITTING",
        )
        before = json.dumps(witness, sort_keys=True)
        current["terminalReceipt"] = None
        effective = helper._effective_tuple(observed)
        records = {entry["name"]: entry["identity"] for entry in witness["config"]}
        with (
            mock.patch.object(helper, "_read_finalization_witness", return_value=(witness, data)),
            mock.patch.object(helper, "_controller_commit_witness", return_value=(
                commit, commit_data, helper._finalization_digest(commit_data),
            )),
            mock.patch.object(helper, "_file_record", side_effect=lambda fd, name: records[name]),
            mock.patch.object(helper, "_receipt_residuals") as residual,
            mock.patch.object(helper, "_receipt_runtime_binding") as runtime,
        ):
            helper._absence_receipt(11, 12, "/state", current, origin, effective)
            residual.assert_called_once_with(
                11, 12, "/state", current, witness, inspect=None,
            )
            runtime.assert_not_called()
            for field, replacement in (
                ("phase", "COMMITTED"), ("containerId", "0" * 64),
                ("providerFinalizationDigest", "0" * 64),
                ("ownedChild", {"pid": 101}),
                ("commitSubstep", "replacement-create-intent"),
                ("commitSubstep", "replacement-container-authorized"),
                ("latestAttemptId", current["incidentId"] + ":0"),
            ):
                changed = dict(current, **{field: replacement})
                with self.subTest(field=field), self.assertRaises(helper.ProviderError):
                    helper._absence_receipt(11, 12, "/state", changed, origin, effective)
            with self.assertRaises(helper.ProviderError):
                helper._absence_receipt(
                    11, 12, "/state", current, origin,
                    dict(effective, APP_PUSH_DISCOVERY_ENABLED="true"),
                )
        self.assertEqual(before, json.dumps(witness, sort_keys=True))

    def test_committing_and_terminal_replay_require_receipt_without_live_transaction(self) -> None:
        for phase, outcome in (("COMMITTING", "finalization-only"), ("COMMITTED", "already-completed")):
            with self.subTest(phase=phase):
                context = live_context(phase)
                value, _, transaction, receipt = self.run_proof(context)
                self.assertEqual(outcome, value["outcome"])
                transaction.assert_not_called()
                receipt.assert_called_once()
                with self.assertRaises(helper.ProviderError):
                    self.run_proof(context, receipt_error=True)

    def test_receipt_required_phases_cannot_fall_back_to_live_proof(self) -> None:
        context = live_context("COMMITTING")
        context[3]["providerFinalizationDigest"] = None
        with self.assertRaises(helper.ProviderError):
            self.run_proof(context)

    def test_terminal_receipt_replay_is_exact_and_read_only(self) -> None:
        self.validate_terminal_receipt(self.receipt_context())
        for index, field, replacement in (
            (1, "providerFinalizationDigest", "0" * 64),
            (1, "terminalReceipt", "0" * 64),
            (1, "operationEpoch", 2),
            (1, "incidentId", "0" * 32),
            (1, "evidenceDigest", "0" * 64),
            (3, "containerId", "0" * 64),
            (3, "configHash", "a" * 64),
        ):
            context = self.receipt_context()
            context[index][field] = replacement
            with self.subTest(index=index, field=field), self.assertRaises(helper.ProviderError):
                self.validate_terminal_receipt(context)

    def test_one_next_attempt_replacement_uses_original_immutable_receipt(self) -> None:
        for phase in ("COMMITTING", "COMMITTED"):
            with self.subTest(phase=phase):
                context = self.receipt_context(phase)
                _, current, observed, _, _, witness, data = context
                current.update(
                    containerId="a" * 64,
                    latestAttemptId=current["incidentId"] + ":2",
                    commitSubstep="replacement-policy-restored"
                    if phase == "COMMITTED" else "replacement-provider-cleanup",
                )
                observed["Id"] = current["containerId"]
                immutable = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
                self.validate_terminal_receipt(context)
                self.assertEqual(data, immutable)
                self.assertEqual(data, json.dumps(witness, sort_keys=True, separators=(",", ":")).encode())

    def test_replacement_refuses_absent_baseline_stale_attempt_and_unknown_child(self) -> None:
        for field, replacement in (
            ("latestAttemptId", None),
            ("latestAttemptId", "d" * 32 + ":1"),
            ("latestAttemptId", "a" * 32 + ":2"),
            ("latestAttemptId", "d" * 32 + ":18446744073709551616"),
            ("containerId", "b" * 64),
            ("configHash", "b" * 64),
            ("operationEpoch", 2),
            ("ownedChild", {"pid": 101}),
            ("phase", "VERIFYING"),
        ):
            context = self.receipt_context("COMMITTING")
            _, current, observed, commit, _, witness, _ = context
            current.update(
                containerId="a" * 64, latestAttemptId=current["incidentId"] + ":2",
                commitSubstep="replacement-provider-cleanup",
            )
            observed["Id"] = current["containerId"]
            current[field] = replacement
            with self.subTest(field=field, value=replacement), self.assertRaises(helper.ProviderError):
                helper._receipt_runtime_binding(witness, current, commit, observed)
        for baseline in (None, "", "malformed", "a" * 32 + ":1", "d" * 32 + ":0"):
            context = self.receipt_context("COMMITTING")
            _, current, observed, commit, _, witness, _ = context
            current.update(
                containerId="a" * 64, latestAttemptId=current["incidentId"] + ":2",
                commitSubstep="replacement-provider-cleanup",
            )
            observed["Id"] = current["containerId"]
            witness["startAttemptId"] = baseline
            with self.subTest(baseline=baseline), self.assertRaises(helper.ProviderError):
                helper._receipt_runtime_binding(witness, current, commit, observed)

    def test_replacement_requires_independent_health_and_unchanged_exact_tuple(self) -> None:
        for path, replacement in (
            (("State", "Running"), False),
            (("State", "Health", "Status"), "unhealthy"),
            (("HostConfig", "RestartPolicy", "Name"), "always"),
            (("Image",), "sha256:" + "a" * 64),
            (("Config", "Labels", "org.opencontainers.image.revision"), "a" * 40),
            (("Config", "Labels", "org.opencontainers.image.version"), "9.9.9"),
        ):
            context = self.receipt_context("COMMITTING")
            _, current, observed, commit, _, witness, _ = context
            current.update(
                containerId="a" * 64, latestAttemptId=current["incidentId"] + ":2",
                commitSubstep="replacement-container-authorized",
            )
            observed["Id"] = current["containerId"]
            target = observed
            for name in path[:-1]:
                target = target[name]
            target[path[-1]] = replacement
            with self.subTest(path=path), self.assertRaises(helper.ProviderError):
                helper._receipt_runtime_binding(witness, current, commit, observed)
            if path[0] == "State":
                helper._receipt_runtime_binding(
                    witness, current, commit, observed, require_replacement_health=False,
                )
            else:
                with self.subTest(admission=path), self.assertRaises(helper.ProviderError):
                    helper._receipt_runtime_binding(
                        witness, current, commit, observed, require_replacement_health=False,
                    )

    def test_private_witness_requires_strict_incident_start_attempt_baseline(self) -> None:
        for attempt in (
            None, "", "c" * 32 + ":0", "d" * 32 + ":1",
            "c" * 32 + ":18446744073709551616",
        ):
            witness = finalization_witness()
            witness["startAttemptId"] = attempt
            with self.subTest(attempt=attempt), self.assertRaises(helper.ProviderError):
                helper._validate_finalization_witness(witness)

    def test_finalization_resume_accepts_bound_replacement_but_preparation_does_not(self) -> None:
        for substep in (
            "replacement-container-authorized",
            "replacement-provider-cleanup",
            "replacement-terminal-policy-intent",
            "replacement-policy-restored",
        ):
            with self.subTest(substep=substep):
                context = self.receipt_context("COMMITTING")
                origin, current, observed, commit, commit_data, witness, data = context
                current.update(
                    containerId="a" * 64, latestAttemptId=current["incidentId"] + ":2",
                    commitSubstep=substep,
                )
                observed["Id"] = current["containerId"]
                if substep in {
                    "replacement-terminal-policy-intent",
                    "replacement-policy-restored",
                }:
                    observed["HostConfig"]["RestartPolicy"]["Name"] = "unless-stopped"
                info = mock.Mock(st_mode=stat.S_IFDIR | 0o700, st_uid=0)
                with (
                    mock.patch.multiple(
                        helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                        O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                    ),
                    mock.patch.object(helper, "_timepad_current", return_value=(
                        helper._timepad_state_module(), origin, current,
                    )),
                    mock.patch.object(helper, "_validate_state_directory"),
                    mock.patch.object(helper.os, "open", return_value=12),
                    mock.patch.object(helper.os, "fstat", return_value=info),
                    mock.patch.object(helper.os, "close"),
                    mock.patch.object(helper, "_directory_record"),
                    mock.patch.object(helper, "_controller_commit_witness", return_value=(
                        commit, commit_data, helper._finalization_digest(commit_data),
                    )),
                    mock.patch.object(helper, "_read_finalization_witness", return_value=(witness, data)),
                ):
                    result = helper._finalization_context(
                        current["runId"], "/state", "final-deploy",
                        json.dumps([observed]).encode(), 9, for_resume=True,
                    )
                    self.assertEqual(12, result[1])
                    self.assertEqual(commit_data, result[-1])
                    with self.assertRaises(helper.ProviderError):
                        helper._finalization_context(
                            current["runId"], "/state", "final-deploy",
                            json.dumps([observed]).encode(), 9, for_resume=False,
                        )
                    for child in ({"lifecycle": "released"}, {"lifecycle": "reaped"}):
                        current["ownedChild"] = child
                        with self.assertRaises(helper.ProviderError):
                            helper._finalization_context(
                                current["runId"], "/state", "final-deploy",
                                json.dumps([observed]).encode(), 9, for_resume=True,
                            )
                    current["ownedChild"] = None
                    current["latestAttemptId"] = current["incidentId"] + ":1"
                    with self.assertRaises(helper.ProviderError):
                        helper._finalization_context(
                            current["runId"], "/state", "final-deploy",
                            json.dumps([observed]).encode(), 9, for_resume=True,
                        )

    def test_same_container_retries_preserve_original_cleanup_witness(self) -> None:
        for phase in ("COMMITTING", "COMMITTED"):
            for sequence in (1, 2, 3, (1 << 64) - 1):
                context = self.receipt_context(phase)
                _, current, _, _, _, witness, data = context
                current["latestAttemptId"] = current["incidentId"] + f":{sequence}"
                with self.subTest(phase=phase, sequence=sequence):
                    self.validate_terminal_receipt(context)
                    self.assertEqual(
                        data,
                        json.dumps(witness, sort_keys=True, separators=(",", ":")).encode(),
                    )
        context = self.receipt_context("COMMITTING")
        context[1].update(
            containerId="a" * 64, latestAttemptId=context[1]["incidentId"] + ":3",
            commitSubstep="replacement-provider-cleanup",
        )
        context[2]["Id"] = context[1]["containerId"]
        self.validate_terminal_receipt(context)
        # A different container without the durable, one-way replacement
        # authorization is not a same-container retry.
        context[1]["commitSubstep"] = "provider-cleanup"
        with self.assertRaises(helper.ProviderError):
            self.validate_terminal_receipt(context)

    def test_missing_corrupt_and_wrong_terminal_receipt_do_not_mutate(self) -> None:
        context = self.receipt_context()
        origin, current, observed = context[:3]
        for error in (
            helper.ProviderError("RECOVERY_REQUIRED"), FileNotFoundError(),
        ):
            with (
                mock.patch.object(helper, "_read_finalization_witness", side_effect=error),
                mock.patch.object(helper.os, "unlink") as unlink,
                mock.patch.object(helper.os, "write") as write,
                self.assertRaises((helper.ProviderError, FileNotFoundError)),
            ):
                helper._live_resume_receipt(11, 12, "/state", current, origin, observed)
            unlink.assert_not_called()
            write.assert_not_called()
        info = mock.Mock(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1, st_size=1)
        for data in (b"{", b"{}", b'{"schema":"wrong"}'):
            with (
                mock.patch.object(helper.os, "stat", return_value=info),
                mock.patch.object(helper, "_read_child_file", return_value=({"size": len(data)}, data)) as read,
                self.assertRaises(helper.ProviderError),
            ):
                helper._read_finalization_witness(12)
            read.assert_called_once_with(12, "provider-finalization.json", helper.MAX_FINALIZATION_BYTES)

    def test_receipt_residuals_accept_only_ordered_next_shape_without_cleanup(self) -> None:
        context = self.receipt_context("COMMITTING", enabled=True)
        origin, current, observed, commit, commit_data, witness, data = context
        entries = witness["transaction"]["entries"]
        config_records = {entry["name"]: entry["identity"] for entry in witness["config"]}
        tx_records = {
            name: entry["identity"]
            for entry in entries for name in (entry["name"], entry["quarantineName"])
        }
        full = [e["name"] for e in entries]
        shapes = [(full[i:], True) for i in range(4)]
        shapes += [
            ([e["quarantineName"]] + full[i + 1:], True)
            for i, e in enumerate(entries)
        ]
        shapes += [
            (["identity.json"], False),
            (["identity.json", "publication"], False),
            (["snapshot", "unowned"], False),
            ([entries[0]["name"], entries[0]["quarantineName"]] + full[1:], False),
            ([entries[0]["quarantineName"], entries[1]["quarantineName"], "publication"], False),
        ]
        credential_data = b"fixture-private-credential"
        expected_credential = witness["durableCredential"]
        expected_credential["sha256"] = helper._finalization_digest(credential_data)
        data = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
        current["providerFinalizationDigest"] = helper._finalization_digest(data)

        for names, valid in shapes:
            publication = any(name in names for name in (
                "publication", entries[-1]["quarantineName"],
            ))
            info = mock.Mock(
                st_dev=expected_credential["device"], st_ino=expected_credential["inode"],
                st_uid=0, st_gid=10001, st_mode=stat.S_IFREG | 0o440,
                st_size=expected_credential["size"], st_mtime_ns=expected_credential["mtimeNs"],
                st_nlink=2 if publication else 1,
            )

            def file_record(fd, name, **kwargs):
                return dict(config_records[name] if fd == 12 else tx_records[name])

            with self.subTest(names=names), contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.multiple(
                    helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                    O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                ))
                stack.enter_context(mock.patch.object(
                    helper, "_read_finalization_witness", return_value=(witness, data),
                ))
                stack.enter_context(mock.patch.object(
                    helper, "_controller_commit_witness", return_value=(
                        commit, commit_data, helper._finalization_digest(commit_data),
                    ),
                ))
                stack.enter_context(mock.patch.object(
                    helper, "_file_record", side_effect=file_record,
                ))
                stack.enter_context(mock.patch.object(helper.os, "stat"))
                stack.enter_context(mock.patch.object(
                    helper, "_marker", return_value=witness["pointer"],
                ))
                stack.enter_context(mock.patch.object(helper.os.path, "lexists", return_value=True))
                stack.enter_context(mock.patch.object(helper.os, "open", side_effect=[13, 14]))
                stack.enter_context(mock.patch.object(helper.os, "close"))
                stack.enter_context(mock.patch.object(helper.os, "fstat"))
                stack.enter_context(mock.patch.object(helper, "_lock_directory"))
                stack.enter_context(mock.patch.object(
                    helper, "_directory_record", side_effect=[
                        witness["transaction"]["directory"],
                        witness["transaction"]["parent"],
                    ],
                ))
                stack.enter_context(mock.patch.object(
                    helper, "_iter_directory_fd_names", return_value=names,
                ))
                stack.enter_context(mock.patch.object(
                    helper, "_open_regular", return_value=(15, info, credential_data),
                ))
                stack.enter_context(mock.patch.object(helper, "_validate_credential"))
                unlink = stack.enter_context(mock.patch.object(helper.os, "unlink"))
                write = stack.enter_context(mock.patch.object(helper.os, "write"))
                fsync = stack.enter_context(mock.patch.object(helper.os, "fsync"))
                if valid:
                    helper._live_resume_receipt(11, 12, "/state", current, origin, observed)
                else:
                    with self.assertRaises(helper.ProviderError):
                        helper._live_resume_receipt(11, 12, "/state", current, origin, observed)
            unlink.assert_not_called()
            write.assert_not_called()
            fsync.assert_not_called()

    def test_private_cli_requires_inherited_lock_and_contention_blocks_dispatch(self) -> None:
        with (
            mock.patch.object(helper, "_deploy_lock") as lock,
            mock.patch.object(helper, "_dispatch") as dispatch,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(1, helper.main(["live-resume"]))
        lock.assert_not_called()
        dispatch.assert_not_called()
        for extra in (
            ["--phase", "candidate"], ["--outcome", "committed"],
            ["--protected-path", "/private"], ["--retention-state", "/private"],
        ):
            with (
                self.subTest(extra=extra),
                mock.patch.object(helper, "_deploy_lock") as lock,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(1, helper.main(["live-resume", "--deploy-lock-fd", "9"] + extra))
            lock.assert_not_called()

        @contextlib.contextmanager
        def contended(*args, **kwargs):
            raise helper.ProviderError("RECOVERY_REQUIRED")
            yield 9

        with (
            mock.patch.object(helper, "_deploy_lock", contended),
            mock.patch.object(helper, "_dispatch") as dispatch,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(1, helper.main(["live-resume", "--deploy-lock-fd", "9"]))
        dispatch.assert_not_called()

    def test_private_cli_dispatch_is_inside_inherited_lock(self) -> None:
        events = []

        @contextlib.contextmanager
        def locked(root, inherited_fd, **kwargs):
            self.assertEqual(9, inherited_fd)
            events.append("enter")
            yield inherited_fd
            events.append("exit")

        with (
            mock.patch.object(helper, "_deploy_lock", locked),
            mock.patch.object(
                helper, "_dispatch", side_effect=lambda args: events.append(("dispatch", args.active_deploy_lock_fd))
            ),
        ):
            self.assertEqual(0, helper.main(["live-resume", "--deploy-lock-fd", "9"]))
        self.assertEqual(["enter", ("dispatch", 9), "exit"], events)

    def test_disabled_live_proof_does_not_adopt_unrelated_durable_credential(self) -> None:
        marker = {
            "schemaVersion": 1, "runKey": "31885558214-1", "phase": "verifying",
            "providerEnabled": False, "durableDisposition": "none",
        }
        with (
            mock.patch.object(helper, "_marker", return_value=marker),
            mock.patch.object(helper.os.path, "lexists", return_value=False),
            mock.patch.object(helper, "_read_existing") as read,
        ):
            self.assertEqual(marker, helper._live_resume_transaction(
                "31885558214-1", "/state", inspection(False), predecessor=False
            ))
        read.assert_not_called()

    def test_enabled_live_proof_requires_intact_created_or_reused_transaction(self) -> None:
        credential = json.dumps({
            "type": "service_account", "project_id": "meeting-1d258",
            "client_email": "fixture@example.invalid", "client_id": "fixture-id",
            "private_key_id": "fixture-key",
            "private_key": "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
            "token_uri": "https://oauth2.example.invalid/token",
        }).encode()
        previous = {"device": 1, "inode": 2, "mtimeNs": 3, "ctimeNs": 4}
        durable = dict(previous, inode=5)
        identity = {"schemaVersion": 1, "predecessor": previous, "durable": durable}
        identity_data = json.dumps(identity).encode()

        for disposition in ("created", "reused"):
            for failure in (None, "missing-snapshot", "wrong-durable", "extra-file", "extra-link"):
                observed = inspection(True)
                marker = {
                    "schemaVersion": 1, "runKey": "31885558214-1", "phase": "applying",
                    "providerEnabled": True, "durableDisposition": disposition,
                }
                names = ["identity.json", "snapshot"]
                if disposition == "created":
                    names.append("publication")
                if failure == "missing-snapshot":
                    names.remove("snapshot")
                if failure == "extra-file":
                    names.append("foreign")
                info = mock.Mock(
                    st_uid=0, st_gid=10001, st_mode=stat.S_IFREG | 0o440,
                    st_nlink=(2 if disposition == "created" else 1)
                    + (1 if failure == "extra-link" else 0),
                )

                def child(fd, name, limit):
                    return {}, identity_data if name == "identity.json" else credential

                actual_identity = dict(durable, inode=6) if failure == "wrong-durable" else durable
                with (
                    self.subTest(disposition=disposition, failure=failure),
                    mock.patch.multiple(
                        helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                        O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                    ),
                    mock.patch.object(helper, "_marker", return_value=marker),
                    mock.patch.object(helper, "_validate_transaction"),
                    mock.patch.object(helper.os, "open", return_value=13),
                    mock.patch.object(helper.os, "close"),
                    mock.patch.object(helper, "_lock_directory"),
                    mock.patch.object(helper, "_iter_directory_fd_names", return_value=names),
                    mock.patch.object(helper, "_read_child_file", side_effect=child),
                    mock.patch.object(helper, "_read_existing", return_value=(actual_identity, credential)),
                    mock.patch.object(helper.os, "stat", return_value=info),
                    mock.patch.object(helper.os.path, "isfile", return_value=True),
                    mock.patch.object(helper.os.path, "islink", return_value=False),
                    mock.patch.object(helper.os, "unlink") as unlink,
                    mock.patch.object(helper.os, "write") as write,
                ):
                    if failure is None:
                        self.assertEqual(marker, helper._live_resume_transaction(
                            "31885558214-1", "/state", observed, predecessor=False,
                        ))
                    else:
                        with self.assertRaises(helper.ProviderError):
                            helper._live_resume_transaction(
                                "31885558214-1", "/state", observed, predecessor=False,
                            )
                unlink.assert_not_called()
                write.assert_not_called()

    def test_live_marker_rejects_wrong_run_phase_enabled_and_disposition(self) -> None:
        base = {
            "schemaVersion": 1, "runKey": "31885558214-1", "phase": "verifying",
            "providerEnabled": False, "durableDisposition": "none",
        }
        for field, replacement in (
            ("phase", "preparing"), ("phase", "finalizing"),
            ("providerEnabled", True), ("durableDisposition", "created"),
        ):
            with (
                self.subTest(field=field, replacement=replacement),
                mock.patch.object(helper, "_marker", return_value=dict(base, **{field: replacement})),
                self.assertRaises(helper.ProviderError),
            ):
                helper._live_resume_transaction(
                    "31885558214-1", "/state", inspection(False), predecessor=False,
                )
        with (
            mock.patch.object(helper, "_read_private", return_value=json.dumps(
                dict(base, runKey="foreign-run")
            ).encode()),
            self.assertRaises(helper.ProviderError),
        ):
            helper._marker("/state", "31885558214-1")

    def test_config_sidecar_requires_exact_size_digest_and_regular_root_owned_source(self) -> None:
        data = b"fixture-private-config"
        digest = helper._finalization_digest(data)

        def read(run_fd, name, limit):
            if name.endswith(".identity"):
                return {}, sidecar
            return {"sha256": digest}, data

        for sidecar in (
            f"1:2:33152:0:0:{len(data)}:3:4:{digest}\n".encode(),
            f"1:2:33152:0:0:999:3:4:{digest}\n".encode(),
            f"1:2:33152:1:0:{len(data)}:3:4:{digest}\n".encode(),
            f"1:2:33152:0:0:{len(data)}:3:4:{'0' * 64}\n".encode(),
        ):
            with mock.patch.object(helper, "_read_child_file", side_effect=read):
                if sidecar.startswith(f"1:2:33152:0:0:{len(data)}:3:4:{digest}".encode()):
                    helper._live_resume_config(12, {"phase": "VERIFYING"})
                else:
                    with self.assertRaises(helper.ProviderError):
                        helper._live_resume_config(12, {"phase": "VERIFYING"})

    def test_original_predecessor_tuple_and_hash_require_same_run_private_records(self) -> None:
        context = live_context("PREPARED")
        current, observed = context[3], context[4]["inspection"][0]
        previous = current["predecessor"]["tuple"]
        records = {
            "previous-image-id": b"sha256:" + previous["platformImageId"].encode() + b"\n",
            "previous-revision": previous["revision"].encode() + b"\n",
            "previous-version": previous["version"].encode() + b"\n",
            "previous-runtime-config-hash": b"0" * 64 + b"\n",
            "previous-image": b"fixture.invalid/backend@sha256:"
            + previous["repositoryDigest"].encode() + b"\n",
        }

        def read(fd, name, limit):
            return {}, records[name]

        with mock.patch.object(helper, "_read_child_file", side_effect=read):
            helper._live_resume_predecessor(12, current, observed)
            for name in records:
                original = records[name]
                records[name] = b"conflicting"
                with self.subTest(name=name), self.assertRaises(helper.ProviderError):
                    helper._live_resume_predecessor(12, current, observed)
                records[name] = original

    def test_hostile_json_and_duplicate_fields_have_fixed_errors(self) -> None:
        for data in (
            b"[" * 4096 + b"0" + b"]" * 4096,
            b'{"schema":"private-canary","schema":"private-canary"}',
        ):
            with self.assertRaises(helper.ProviderError) as error:
                helper._json(data, "recovery")
            self.assertEqual("RECOVERY_REQUIRED", error.exception.category)


def prepared_proof(current: dict) -> dict:
    record = finalization_witness()["config"][0]["identity"]
    return {
        "schema": helper.PREPARED_SCHEMA,
        "binding": {key: current[key] for key in helper.PREPARED_BINDING},
        "config": [
            {"name": name, "identity": dict(record, inode=index)}
            for index, name in enumerate(helper.PREPARED_CONFIG, start=100)
        ],
        "provider": {
            "providerEnabled": False, "durableDisposition": "none", "transaction": None,
        },
        "targetConfigurationDigest": "1" * 64,
        "effectiveProviderDigest": "2" * 64,
    }


class PreparedProofTests(unittest.TestCase):
    def validate(self, proof: dict, current: dict, *, records: list | None = None) -> dict:
        data = json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()
        current["preparedProofDigest"] = helper._finalization_digest(data)
        with (
            mock.patch.object(helper, "_read_child_file", return_value=({}, data)),
            mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
            mock.patch.object(
                helper, "_prepared_config_records",
                return_value=proof["config"] if records is None else records,
            ),
            mock.patch.object(helper.os, "write") as write,
            mock.patch.object(helper.os, "unlink") as unlink,
        ):
            result = helper._prepared_proof(12, current)
        write.assert_not_called()
        unlink.assert_not_called()
        return result

    def test_frozen_proof_binds_every_operation_identity_and_config_record(self) -> None:
        current = live_context("PREPARED")[3]
        proof = prepared_proof(current)
        self.assertEqual(proof, self.validate(proof, current))
        self.assertLessEqual(len(json.dumps(proof).encode()), helper.MAX_PREPARED_BYTES)
        for key in helper.PREPARED_BINDING:
            changed = json.loads(json.dumps(proof))
            changed["binding"][key] = None
            with self.subTest(binding=key), self.assertRaises(helper.ProviderError):
                self.validate(changed, current)
        changed_records = json.loads(json.dumps(proof["config"]))
        for field in ("device", "inode", "uid", "mode", "links", "mtimeNs", "sha256"):
            changed_records[0]["identity"][field] = "tampered"
            with self.subTest(identity=field), self.assertRaises(helper.ProviderError):
                self.validate(proof, current, records=changed_records)
        data = json.dumps(proof).encode()
        current["preparedProofDigest"] = "0" * 64
        with (
            mock.patch.object(helper, "_read_child_file", return_value=({}, data)),
            mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
            mock.patch.object(helper, "_prepared_config_records") as config,
            self.assertRaises(helper.ProviderError),
        ):
            helper._prepared_proof(12, current)
        config.assert_not_called()

    def test_proof_rejects_unknown_schema_fields_and_provider_shapes(self) -> None:
        current = live_context("PREPARED")[3]
        for field, replacement in (
            ("schema", "unknown"), ("extra", True),
            ("targetConfigurationDigest", "bad"),
            ("effectiveProviderDigest", True),
            ("provider", None),
            ("provider", {"providerEnabled": False, "durableDisposition": "created",
                          "transaction": None}),
            ("provider", {"providerEnabled": True, "durableDisposition": "created",
                          "transaction": {"parent": {}, "directory": {}, "entries": []}}),
        ):
            proof = dict(prepared_proof(current), **{field: replacement})
            with self.subTest(field=field, replacement=replacement), self.assertRaises(helper.ProviderError):
                self.validate(proof, current)

    def test_missing_conflicting_temporary_and_commit_artifacts_refuse(self) -> None:
        current = live_context("PREPARED")[3]
        with (
            mock.patch.object(helper.os, "stat", return_value=mock.Mock()),
            mock.patch.object(helper, "_read_child_file") as read,
            self.assertRaises(helper.ProviderError),
        ):
            helper._prepared_proof(12, current)
        read.assert_not_called()
        with (
            mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
            mock.patch.object(
                helper, "_read_child_file", side_effect=helper.ProviderError("RECOVERY_REQUIRED"),
            ),
            self.assertRaises(helper.ProviderError),
        ):
            helper._prepared_proof(12, current)
        for artifact in (
            "timepad-commit-witness.json", "provider-finalization.json", "terminal.json",
        ):
            def file_stat(name, **kwargs):
                if name != artifact:
                    raise FileNotFoundError
                return mock.Mock()
            with (
                self.subTest(artifact=artifact),
                mock.patch.object(helper.os, "stat", side_effect=file_stat),
                self.assertRaises(helper.ProviderError),
            ):
                helper._prepared_no_commit_files(12)

    def test_intended_target_is_validated_independently_of_predecessor_runtime(self) -> None:
        context = live_context("PREPARED")
        current, envelope = context[3], context[4]
        proof = prepared_proof(current)
        image = helper._inspect(json.dumps(envelope["imageInspection"]).encode())
        config = envelope["targetConfiguration"]
        effective = helper._absence_target_tuple(image, config, current)
        proof.update(
            targetConfigurationDigest=helper._configuration_digest(config),
            effectiveProviderDigest=helper._configuration_digest(effective),
        )
        with (
            mock.patch.object(helper, "_prepared_proof", return_value=proof),
            mock.patch.object(helper, "_live_resume_runtime") as runtime,
        ):
            self.assertEqual((proof, effective), helper._prepared_target(
                12, current, envelope["imageInspection"], config,
            ))
            for replacement in (
                dict(config, unexpected=True),
                {"services": {"backend": {
                    "image": config["services"]["backend"]["image"],
                    "environment": {"APP_PUSH_DISCOVERY_ENABLED": "true"},
                }}},
            ):
                with self.subTest(config=replacement), self.assertRaises(helper.ProviderError):
                    helper._prepared_target(12, current, envelope["imageInspection"], replacement)
        runtime.assert_not_called()

    def test_prepared_inventory_missing_extra_unknown_or_target_runtime_refuses(self) -> None:
        suite = LiveResumeTests()
        for inventory in ([], None, ["unknown"], ["f" * 64, "a" * 64]):
            context = live_context("PREPARED")
            context[4]["backendInventory"] = inventory
            with self.subTest(inventory=inventory), self.assertRaises(helper.ProviderError):
                suite.authority(context)
        for key in ("imageInspection", "targetConfiguration", "backendInventory"):
            context = live_context("PREPARED")
            del context[4][key]
            with self.subTest(missing=key), self.assertRaises(helper.ProviderError):
                suite.authority(context)
        context = live_context("PREPARED")
        observed = context[4]["inspection"][0]
        observed["Image"] = "sha256:" + context[3]["target"]["tuple"]["platformImageId"]
        with self.assertRaises(helper.ProviderError):
            helper._live_resume_runtime(observed, context[3], "admission")

    def test_prepared_same_image_predecessor_is_not_fabricated_target_runtime(self) -> None:
        context = live_context("PREPARED")
        current, observed = context[3], context[4]["inspection"][0]
        current["predecessor"]["tuple"] = dict(current["target"]["tuple"])
        observed["Image"] = "sha256:" + current["target"]["tuple"]["platformImageId"]
        observed["Config"]["Labels"].update({
            "org.opencontainers.image.revision": current["target"]["tuple"]["revision"],
            "org.opencontainers.image.version": current["target"]["tuple"]["version"],
        })
        self.assertEqual((False, False), helper._live_resume_runtime(
            observed, current, "admission",
        ))
        self.assertIsNone(current["containerId"])
        self.assertIsNone(current["configHash"])

    def test_config_validation_reads_frozen_target_not_original_substitution(self) -> None:
        with (
            mock.patch.object(helper, "_prepared_proof", side_effect=helper.ProviderError("RECOVERY_REQUIRED")) as proof,
            mock.patch.object(helper, "_read_child_file") as read,
            self.assertRaises(helper.ProviderError),
        ):
            helper._live_resume_config(12, {"phase": "PREPARED"})
        proof.assert_called_once()
        read.assert_not_called()

    def test_environment_allows_only_exact_three_release_replacements(self) -> None:
        current = live_context("PREPARED")[3]
        original = (
            b"BACKEND_IMAGE=fixture.invalid/backend@sha256:" + b"a" * 64
            + b"\r\nBACKEND_REVISION=" + b"b" * 40
            + b"\r\nBACKEND_VERSION=1.2.2\r\nPRIVATE_CANARY=untouched\r\n"
        )
        previous_ref = b"fixture.invalid/backend@sha256:" + b"a" * 64 + b"\n"
        records = {"config.env.production": original, "previous-image": previous_ref}
        for name, target, reference in (
            ("config.env.target", current["target"]["tuple"],
             "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
             + current["target"]["tuple"]["repositoryDigest"]),
            ("config.env.previous", current["predecessor"]["tuple"],
             previous_ref.decode().rstrip("\n")),
        ):
            records[name] = (
                f"BACKEND_IMAGE={reference}\r\nBACKEND_REVISION={target['revision']}"
                f"\r\nBACKEND_VERSION={target['version']}\r\nPRIVATE_CANARY=untouched\r\n"
            ).encode()

        def read(fd, name, limit):
            return {}, records[name]

        with mock.patch.object(helper, "_read_child_file", side_effect=read):
            helper._prepared_environment(12, current)
            records["config.env.target"] = records["config.env.target"].replace(
                b"untouched", b"changed",
            )
            with self.assertRaises(helper.ProviderError):
                helper._prepared_environment(12, current)

    def test_atomic_immutable_publication_and_exact_readback(self) -> None:
        module, contract, origin, current, envelope = live_context("PREPARED")
        proof = prepared_proof(current)
        evidence = {
            "rootId": origin["rootId"], "targetId": current["target"]["id"],
            "predecessorId": current["predecessor"]["id"],
            "predecessorContainerId": current["predecessorContainerId"],
            "transitionId": current["transitionId"],
            "target": current["target"]["tuple"], "predecessor": current["predecessor"]["tuple"],
            "operation": current["operation"], "runId": current["runId"],
            "incidentId": current["incidentId"], "ownedRun": current["ownedRun"],
            "toolingDigest": current["toolingDigest"],
        }
        payload = dict(
            schema=helper.PREPARED_INPUT_SCHEMA, evidence=evidence,
            predecessorInspection=envelope["inspection"],
            imageInspection=envelope["imageInspection"],
            targetConfiguration=envelope["targetConfiguration"],
        )
        files = {}
        events = []

        def file_stat(name, **kwargs):
            if name not in files:
                raise FileNotFoundError
            return mock.Mock()

        def write(fd, name, data, mode):
            if name in files:
                raise FileExistsError
            events.append("write")
            files[name] = data

        def rename(fd, source, target):
            events.append("rename")
            files[target] = files.pop(source)

        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(module, "_read_input", return_value=json.dumps(contract).encode()))
            stack.enter_context(mock.patch.object(
                helper, "_timepad_current", return_value=(
                    module, origin, dict(
                        current, phase="READY", operationEpoch=0, runId=None, incidentId=None,
                    ),
                ),
            ))
            stack.enter_context(mock.patch.multiple(
                helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0),
                O_NONBLOCK=getattr(os, "O_NONBLOCK", 0), create=True,
            ))
            stack.enter_context(mock.patch.object(helper, "_open_deploy_state_root", return_value=11))
            stack.enter_context(mock.patch.object(helper, "_lock_directory"))
            stack.enter_context(mock.patch.object(helper.os, "open", return_value=12))
            stack.enter_context(mock.patch.object(helper.os, "close"))
            stack.enter_context(mock.patch.object(helper.os, "stat", side_effect=file_stat))
            stack.enter_context(mock.patch.object(helper.os, "fsync", side_effect=lambda fd: events.append("fsync")))
            stack.enter_context(mock.patch.object(helper, "_validate_state_directory_fd"))
            stack.enter_context(mock.patch.object(helper, "_open_optional_directory_reference", return_value=None))
            stack.enter_context(mock.patch.object(helper, "_iter_directory_fd_names", return_value=[]))
            stack.enter_context(mock.patch.object(helper, "_live_resume_predecessor"))
            stack.enter_context(mock.patch.object(helper, "_prepared_environment"))
            stack.enter_context(mock.patch.object(helper, "_snapshot_source_identity"))
            stack.enter_context(mock.patch.object(helper, "_prepared_transaction", return_value=proof["provider"]))
            stack.enter_context(mock.patch.object(helper, "_prepared_config_records", return_value=proof["config"]))
            stack.enter_context(mock.patch.object(helper, "_write_private_at", side_effect=write))
            stack.enter_context(mock.patch.object(helper, "_rename_noreplace", side_effect=rename))
            stack.enter_context(mock.patch.object(
                helper, "_read_child_file", side_effect=lambda fd, name, limit: ({}, files[name]),
            ))
            output = stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            for _ in range(2):
                helper._prepare_transition_proof(
                    current["runId"], "/state", "final-deploy", json.dumps(payload).encode(), 9,
                )
            replies = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(replies[0], replies[1])
            self.assertEqual("proof-prepared", replies[0]["outcome"])
            self.assertEqual(
                helper._finalization_digest(files["timepad-prepared.json"]),
                replies[0]["preparedProofDigest"],
            )
            self.assertLessEqual(len(files["timepad-prepared.json"]), 8192)
            self.assertEqual(1, events.count("write"))
            self.assertEqual(1, events.count("rename"))
            self.assertEqual("fsync", events[events.index("rename") + 1])
            files["timepad-prepared.json"] += b" "
            with self.assertRaises(helper.ProviderError):
                helper._prepare_transition_proof(
                    current["runId"], "/state", "final-deploy", json.dumps(payload).encode(), 9,
                )
        self.assertNotIn("PRIVATE_CANARY", output.getvalue())

    def test_absence_prepared_validates_frozen_inputs_without_runtime_fabrication(self) -> None:
        context = live_context("PREPARED")
        _, _, _, current, live = context
        envelope = dict(
            schema=helper.ABSENCE_RESUME_SCHEMA, authorization=live["authorization"],
            imageInspection=live["imageInspection"], targetConfiguration=live["targetConfiguration"],
            backendInventory=[],
        )
        with (
            mock.patch.object(helper, "_prepared_absent_transaction") as transaction,
            mock.patch.object(helper, "_live_resume_runtime") as runtime,
            mock.patch.object(helper, "_absence_receipt") as receipt,
        ):
            result = LiveResumeTests().run_proof(context, absence_envelope=envelope)[0]
        self.assertEqual("retry-exact-candidate", result["outcome"])
        transaction.assert_called_once()
        runtime.assert_not_called()
        receipt.assert_not_called()
        self.assertEqual("PREPARED", current["phase"])
        self.assertIsNone(current["containerId"])
        self.assertIsNone(current["configHash"])

    def test_enabled_absence_requires_every_frozen_transaction_identity_and_content(self) -> None:
        credential = json.dumps({
            "type": "service_account", "project_id": helper.EXPECTED_PROJECT,
            "client_email": "fixture@example.invalid", "client_id": "fixture",
            "private_key_id": "fixture", "token_uri": "https://example.invalid/token",
            "private_key": "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
        }).encode()
        durable = {"device": 1, "inode": 2, "mtimeNs": 3, "ctimeNs": 4}
        identity = {"schemaVersion": 1, "predecessor": dict(durable, inode=5), "durable": durable}
        for disposition in ("created", "reused"):
            current = live_context("PREPARED")[3]
            proof = prepared_proof(current)
            frozen = finalization_witness(True)["transaction"]
            names = ["identity.json", "snapshot"]
            if disposition == "created":
                names.append("publication")
            entries = [
                {"name": entry["name"], "identity": entry["identity"]}
                for entry in frozen["entries"] if entry["name"] in names
            ]
            transaction = dict(frozen, entries=entries)
            proof["provider"] = {
                "providerEnabled": True, "durableDisposition": disposition,
                "transaction": transaction,
            }
            self.validate(proof, current)
            for failure in (None, "wrong-inode", "missing-snapshot", "wrong-durable", "extra-link"):
                marker = {
                    "phase": "applying", "providerEnabled": True,
                    "durableDisposition": disposition,
                }
                actual_names = list(names)
                if failure == "missing-snapshot":
                    actual_names.remove("snapshot")

                def record(fd, name, **kwargs):
                    value = dict(next(e["identity"] for e in entries if e["name"] == name))
                    if failure == "wrong-inode":
                        value["inode"] += 100
                    return value

                def read(fd, name, limit):
                    return {}, json.dumps(identity).encode() if name == "identity.json" else credential

                with self.subTest(disposition=disposition, failure=failure), contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.multiple(
                        helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                        O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                    ))
                    stack.enter_context(mock.patch.object(helper, "_marker", return_value=marker))
                    stack.enter_context(mock.patch.object(helper, "_validate_transaction"))
                    stack.enter_context(mock.patch.object(helper, "_open_optional_directory_reference", return_value=13))
                    stack.enter_context(mock.patch.object(helper.os, "open", return_value=14))
                    stack.enter_context(mock.patch.object(helper.os, "close"))
                    stack.enter_context(mock.patch.object(helper.os, "fstat"))
                    stack.enter_context(mock.patch.object(helper, "_lock_directory"))
                    stack.enter_context(mock.patch.object(
                        helper, "_directory_record",
                        side_effect=[transaction["parent"], transaction["directory"]],
                    ))
                    stack.enter_context(mock.patch.object(helper, "_iter_directory_fd_names", return_value=actual_names))
                    stack.enter_context(mock.patch.object(helper, "_file_record", side_effect=record))
                    stack.enter_context(mock.patch.object(helper, "_read_child_file", side_effect=read))
                    stack.enter_context(mock.patch.object(
                        helper, "_read_existing", return_value=(
                            dict(durable, inode=99) if failure == "wrong-durable" else durable,
                            credential,
                        ),
                    ))
                    stack.enter_context(mock.patch.object(
                        helper.os, "stat", return_value=mock.Mock(
                            st_nlink=2 if failure == "extra-link" else 1,
                        ),
                    ))
                    publication = stack.enter_context(mock.patch.object(
                        helper, "_verify_created_publication",
                        side_effect=helper.ProviderError("RECOVERY_REQUIRED")
                        if failure == "extra-link" else None,
                    ))
                    write = stack.enter_context(mock.patch.object(helper.os, "write"))
                    unlink = stack.enter_context(mock.patch.object(helper.os, "unlink"))
                    if failure is None:
                        helper._prepared_absent_transaction(current["runId"], "/state", proof)
                        self.assertEqual(disposition == "created", publication.called)
                    else:
                        with self.assertRaises(helper.ProviderError):
                            helper._prepared_absent_transaction(current["runId"], "/state", proof)
                write.assert_not_called()
                unlink.assert_not_called()


class ExecutionInterlockTests(unittest.TestCase):
    def test_all_public_writers_and_recovery_check_lease_under_lock(self) -> None:
        events = []

        @contextlib.contextmanager
        def locked(*args, **kwargs):
            events.append("lock")
            yield 9
            events.append("unlock")

        for command in (
            "prepare", "verify", "finish", "state-publish", "prepare-finalization",
            "finish-committed-resume", "live-resume", "absence-resume",
            "prepare-transition-proof", "retention-list", "retention-check", "retention-delete",
        ):
            events.clear()
            with (
                self.subTest(command=command),
                mock.patch.object(helper, "_deploy_lock", locked),
                mock.patch.object(
                    helper, "_execution_interlock", side_effect=lambda args, fd: events.append("lease"),
                ),
                mock.patch.object(helper, "_dispatch", side_effect=lambda args: events.append("dispatch")),
            ):
                self.assertEqual(0, helper.main([command, "--deploy-lock-fd", "9"]))
            self.assertEqual(["lock", "lease", "dispatch", "unlock"], events)
        with (
            mock.patch.object(helper, "_deploy_lock", locked),
            mock.patch.object(helper, "_execution_interlock", side_effect=helper.ProviderError("RECOVERY_REQUIRED")),
            mock.patch.object(helper, "_dispatch") as dispatch,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(1, helper.main(["state-publish"]))
        dispatch.assert_not_called()

    def test_lease_requires_inherited_lock_live_attempt_and_work_deadline(self) -> None:
        module = helper._timepad_state_module()
        now = time.monotonic_ns()
        args = helper._parser().parse_args([
            "prepare", "--deploy-lock-fd", "9", "--execution-attempt", "a" * 32,
            "--execution-grant", "b" * 32,
            "--deadline-ns", str(now + 10_000_000_000),
        ])
        lease = {
            "attempt": "a" * 32, "lifecycle": "armed", "workEndNs": now + 20_000_000_000,
            "workerMode": "controller-worker", "firstFailure": None,
        }
        with (
            mock.patch.object(helper.os, "stat"),
            mock.patch.object(module, "_read_execution_lease_locked", return_value=lease),
            mock.patch.object(module, "check_execution_lease") as check,
        ):
            helper._execution_interlock(args, 9)
            check.assert_called_once_with(args.state_root, attempt="a" * 32, deploy_lock_fd=9)
            for field, replacement in (
                ("deploy_lock_fd", None), ("execution_attempt", None),
                ("execution_grant", None),
                ("deadline_ns", None), ("deadline_ns", now + 21_000_000_000),
            ):
                changed = helper._parser().parse_args(["prepare"])
                vars(changed).update(vars(args))
                setattr(changed, field, replacement)
                with self.subTest(field=field), self.assertRaises(helper.ProviderError):
                    helper._execution_interlock(changed, 9)
            for lifecycle in (
                "cancel-forward", "drain-forward", "draining", "quiescence-unconfirmed", "drained",
            ):
                lease["lifecycle"] = lifecycle
                with self.subTest(lifecycle=lifecycle), self.assertRaises(helper.ProviderError):
                    helper._execution_interlock(args, 9)
            lease["lifecycle"] = "armed"
            check.side_effect = module.GuardError("EXECUTION_LEASE_UNRESOLVED")
            with self.assertRaises(helper.ProviderError):
                helper._execution_interlock(args, 9)

    def test_grant_bundle_is_exact_and_rejected_before_lock_or_root_creation(self) -> None:
        valid = [
            "--execution-attempt", "a" * 32, "--execution-grant", "b" * 32,
            "--deadline-ns", str(time.monotonic_ns() + 10_000_000_000),
        ]
        for options in (
            valid[:2], valid[2:4], valid[4:], valid[:4],
            valid[:2] + valid[4:], valid[2:],
            ["--execution-attempt", "../escape"] + valid[2:],
            valid[:2] + ["--execution-grant", "B" * 32] + valid[4:],
            valid[:4] + ["--deadline-ns", str(1 << 63)],
        ):
            with (
                self.subTest(options=options),
                mock.patch.object(helper, "_deploy_lock") as lock,
                mock.patch.object(helper, "_dispatch") as dispatch,
                contextlib.redirect_stderr(io.StringIO()) as error,
            ):
                self.assertEqual(1, helper.main(["state-publish"] + options))
            self.assertEqual("RECOVERY_REQUIRED\n", error.getvalue())
            lock.assert_not_called()
            dispatch.assert_not_called()
        for command in ("check", "check-image", "observe"):
            with (
                self.subTest(command=command),
                mock.patch.object(helper, "_dispatch") as dispatch,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(1, helper.main([command] + valid))
            dispatch.assert_not_called()

    def test_no_lease_preserves_public_api_but_cannot_accept_a_grant(self) -> None:
        args = helper._parser().parse_args(["prepare"])
        with mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError):
            self.assertIsNone(helper._execution_interlock(args, 9))
            args.execution_attempt, args.execution_grant = "a" * 32, "b" * 32
            args.deadline_ns = time.monotonic_ns() + 10_000_000_000
            with self.assertRaises(helper.ProviderError):
                helper._execution_interlock(args, 9)
        self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_deadline_never_resets_nested_budget_or_launches_expired_work(self) -> None:
        with mock.patch.object(helper.time, "monotonic_ns", return_value=100):
            with helper._operation_deadline(200):
                with helper._operation_deadline(300):
                    self.assertEqual(200, helper._DEADLINE_NS.get())
                self.assertEqual(200, helper._DEADLINE_NS.get())
            self.assertIsNone(helper._DEADLINE_NS.get())
            for deadline in (0, 99, 100, True, -1, 1 << 63):
                with self.subTest(deadline=deadline), self.assertRaises(helper.ProviderError):
                    with helper._operation_deadline(deadline):
                        self.fail("expired or invalid deadline entered")
            with (
                mock.patch.object(helper, "_deploy_lock") as lock,
                contextlib.redirect_stderr(io.StringIO()),
            ):
                self.assertEqual(1, helper.main(["state-publish", "--deadline-ns", "99"]))
            lock.assert_not_called()

    def test_directory_lock_contention_is_nonblocking_and_fail_closed(self) -> None:
        flock = mock.Mock()
        with mock.patch.object(helper, "fcntl", mock.Mock(
            flock=flock, LOCK_EX=2, LOCK_NB=4,
        )):
            helper._lock_directory(9)
            flock.assert_called_once_with(9, 6)
            flock.side_effect = BlockingIOError()
            with self.assertRaises(helper.ProviderError):
                helper._lock_directory(9)

    def test_new_run_publication_refuses_unresolved_or_lost_guard(self) -> None:
        module = helper._timepad_state_module()
        scan = mock.MagicMock()
        scan.__enter__.return_value = [pathlib.Path("timepad-guard")]
        with (
            mock.patch.object(helper.os, "scandir", return_value=scan),
            mock.patch.object(module, "_read_guard_locked") as read,
        ):
            for phase in ("READY", "COMMITTED", "ROLLED_BACK"):
                read.return_value = ({}, {"phase": phase})
                helper._timepad_publication_guard("/state")
            for phase in ("PREPARED", "CUTOVER_POSSIBLE", "COMMITTING", "RECOVERY_REQUIRED"):
                read.return_value = ({}, {"phase": phase})
                with self.subTest(phase=phase), self.assertRaises(helper.ProviderError):
                    helper._timepad_publication_guard("/state")
            read.side_effect = module.GuardError("GUARD_STATE_LOST")
            with self.assertRaises(helper.ProviderError):
                helper._timepad_publication_guard("/state")
        scan.__enter__.return_value = [pathlib.Path(".timepad-bootstrap-fixture")]
        with (
            mock.patch.object(helper.os, "scandir", return_value=scan),
            self.assertRaises(helper.ProviderError),
        ):
            helper._timepad_publication_guard("/state")


class ProviderLiveGrantTests(unittest.TestCase):
    def setUp(self) -> None:
        import test_vps_timepad_supervisor

        self.supervisor = test_vps_timepad_supervisor
        self.module = helper._timepad_state_module()
        self.args = helper._parser().parse_args([
            "prepare", "--deploy-lock-fd", "9", "--execution-attempt", "a" * 32,
            "--execution-grant", "b" * 32, "--deadline-ns", "200",
        ])
        self.lease = {
            "attempt": self.args.execution_attempt, "workerMode": "controller-worker",
            "lifecycle": "armed", "workEndNs": 300, "hardEndNs": 400,
            "supervisor": {"pid": 101, "startTicks": 10, "bootId": "fixture"},
            "operation": "deploy", "firstFailure": None, "rollbackIssued": False,
        }
        self.client = mock.Mock(
            attempt=self.args.execution_attempt, role=self.lease["workerMode"],
            supervisor=self.lease["supervisor"],
        )
        self.reply = {
            "attempt": self.args.execution_attempt, "grantId": self.args.execution_grant,
            "endNs": self.args.deadline_ns, "role": self.lease["workerMode"],
            "name": "provider",
        }
        self.client.request.return_value = self.reply
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(helper.time, "monotonic_ns", return_value=100))
        self.stack.enter_context(mock.patch.object(helper.os, "stat"))
        self.stack.enter_context(mock.patch.object(
            self.module, "_read_execution_lease_locked", side_effect=lambda root: self.lease,
        ))
        self.stack.enter_context(mock.patch.object(self.module, "check_execution_lease"))
        self.factory = self.stack.enter_context(mock.patch.object(
            self.supervisor, "WorkerClient", return_value=self.client,
        ))

    @contextlib.contextmanager
    def authority(self):
        with helper._operation_deadline(self.args.deadline_ns):
            lease = helper._execution_interlock(self.args, 9)
            with helper._execution_mutation(self.args, lease):
                yield

    def revoke(self, *args, **kwargs):
        self.client.request.side_effect = self.supervisor.SupervisorError("private-canary")

    def test_cleanup_reserve_is_exclusive_to_read_only_stop_request_proof(self):
        self.lease.update(
            workerMode="fail-closed-worker", lifecycle="draining", operation="forward-recover",
            firstFailure="RECOVERY_RETRY_RUNTIME_FAILED", firstStatus=1, workEndNs=150,
        )
        self.client.role = self.reply["role"] = "fail-closed-worker"
        self.reply["name"] = "cleanup-stop"
        current = {
            "executionAttempt": self.args.execution_attempt, "phase": "VERIFYING", "ownedChild": None,
            "containerId": "c" * 64, "configHash": "d" * 64,
            "target": {"tuple": {"platformImageId": "e" * 64}},
            "runtimeRequest": {
                "executionAttempt": self.args.execution_attempt, "operation": "stop",
                "containerId": "c" * 64, "configHash": "d" * 64, "imageId": "e" * 64,
                "lifecycle": "acknowledged",
            },
        }
        with mock.patch.object(self.module, "_read_guard_locked", return_value=({}, current)):
            self.args.command = "runtime-request-proof"
            with self.authority():
                helper._deadline_check()
            for command in ("prepare", "verify", "finish", "state-publish", "live-resume", "retention-delete"):
                self.args.command = command
                with self.subTest(command=command), self.assertRaises(helper.ProviderError):
                    with self.authority():
                        self.fail("cleanup admitted provider work")
            self.args.command = "runtime-request-proof"
            for field, value in (("phase", "COMMITTING"), ("executionAttempt", "f" * 32)):
                with mock.patch.dict(current, {field: value}), self.assertRaises(helper.ProviderError):
                    with self.authority():
                        self.fail("unbound stop proof admitted")

    def test_live_grant_is_checked_at_entry_each_boundary_and_exit_without_renewal(self) -> None:
        with self.authority():
            for _ in range(3):
                helper._deadline_check()
        self.assertEqual(5, self.client.request.call_count)
        self.assertEqual([mock.call(
            "validate-grant", grantId="b" * 32, endNs=200,
        )] * 5, self.client.request.call_args_list)
        self.factory.assert_called_once_with(self.args.state_root)
        self.client.close.assert_called_once()
        self.assertIsNone(helper._EXECUTION_CHECK.get())
        self.assertIsNone(helper._DEADLINE_NS.get())

    def test_stale_durable_lease_cannot_publish_after_live_revocation(self) -> None:
        with (
            mock.patch.object(helper.os, "open") as opened,
            mock.patch.object(helper.os, "write") as written,
            mock.patch.object(helper, "_check_ancestors"),
            self.assertRaises(helper.ProviderError) as error,
        ):
            with self.authority():
                self.revoke()
                helper._write_private("/private/output", b"fixture", 0o600)
        self.assertEqual("RECOVERY_REQUIRED", error.exception.category)
        opened.assert_not_called()
        written.assert_not_called()
        self.assertEqual("armed", self.lease["lifecycle"])
        self.client.close.assert_called_once()
        self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_mismatched_live_identity_and_every_grant_binding_refuse(self) -> None:
        for field, replacement in (
            ("attempt", "c" * 32), ("role", "rollback-worker"),
            ("supervisor", {"pid": 999}),
        ):
            original = getattr(self.client, field)
            setattr(self.client, field, replacement)
            with self.subTest(identity=field), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("mismatched private identity entered")
            setattr(self.client, field, original)
        for field, replacement in (
            ("attempt", "c" * 32), ("grantId", "c" * 32), ("endNs", 201),
            ("role", "rollback-worker"), ("name", "state-publish"), ("extra", True),
        ):
            self.client.request.return_value = dict(self.reply, **{field: replacement})
            with self.subTest(binding=field), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("mismatched live grant entered")
        self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_refused_private_channel_and_deadline_crossing_are_fixed_failures(self) -> None:
        self.factory.side_effect = self.supervisor.SupervisorError("private-canary")
        with self.assertRaises(helper.ProviderError) as error:
            with self.authority():
                self.fail("missing private channel entered")
        self.assertEqual("RECOVERY_REQUIRED", error.exception.category)
        self.factory.side_effect = None

        def expiry(*args, **kwargs):
            helper.time.monotonic_ns.return_value = 200
            return self.reply

        self.client.request.side_effect = expiry
        with self.assertRaises(helper.ProviderError):
            with self.authority():
                self.fail("reply past absolute deadline entered")
        self.client.close.assert_called_once()
        self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_registered_budget_is_not_reset_and_cleanup_reserve_is_never_provider_work(self) -> None:
        self.lease.update(lifecycle="registered", workEndNs=None)
        with self.authority():
            self.assertEqual(200, helper._DEADLINE_NS.get())
        for changes in (
            {"lifecycle": "armed", "workEndNs": 199},
            {"lifecycle": "draining", "workEndNs": 199, "workerMode": "fail-closed-worker"},
            {"lifecycle": "armed", "workEndNs": 300, "firstFailure": "TERM"},
            {"lifecycle": "rolling-back", "workEndNs": 300, "workerMode": "controller-worker"},
        ):
            self.lease.update(changes)
            with self.subTest(changes=changes), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("reserve/cancelled authority entered")

    def test_registered_recovery_only_allows_read_only_request_reconciliation(self) -> None:
        self.lease.update(operation="forward-recover", lifecycle="registered", workEndNs=None)
        self.reply["name"] = "recovery-admission"
        for command in ("live-resume", "absence-resume", "runtime-request-proof"):
            self.args.command = command
            with self.subTest(command=command), self.authority():
                helper._deadline_check()
        for command in ("prepare", "finish", "state-publish", "prepare-finalization"):
            self.args.command = command
            with self.subTest(command=command), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("recovery admission authorized mutation")
        self.args.command = "runtime-request-proof"
        self.revoke()
        with self.assertRaises(helper.ProviderError):
            with self.authority():
                self.fail("revoked reconciliation entered")

    def test_rollback_admission_stays_read_only_and_admitted_rollback_uses_its_own_grant(self) -> None:
        self.lease.update(
            workerMode="rollback-worker", lifecycle="rollback-admission",
            firstFailure="TERM", rollbackIssued=True,
        )
        self.client.role = self.reply["role"] = "rollback-worker"
        self.reply["name"] = "rollback-admission"
        for command in ("verify", "live-resume", "absence-resume"):
            self.args.command = command
            with self.subTest(command=command), self.authority():
                helper._deadline_check()
        for command in ("prepare", "finish", "state-publish", "prepare-finalization",
                        "finish-committed-resume", "prepare-transition-proof", "retention-delete"):
            self.args.command = command
            with self.subTest(command=command), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("read-only admission authorized mutation")
        self.lease["lifecycle"] = "rolling-back"
        self.args.command = "finish"
        self.reply["name"] = "provider"
        with self.authority():
            helper._deadline_check()
        for changes in ({"operation": "forward-recover"}, {"rollbackIssued": False}):
            self.lease.update(changes)
            with self.subTest(changes=changes), self.assertRaises(helper.ProviderError):
                with self.authority():
                    self.fail("unadmitted rollback entered")

    def test_retention_worker_only_has_existing_retention_commands(self) -> None:
        self.lease.update(workerMode="retention-worker", operation="retention")
        self.client.role = self.reply["role"] = "retention-worker"
        for command in ("retention-list", "retention-check", "retention-delete"):
            self.args.command = command
            with self.subTest(command=command), self.authority():
                helper._deadline_check()
        self.args.command = "prepare"
        with self.assertRaises(helper.ProviderError):
            with self.authority():
                self.fail("retention authorized provider preparation")

    def test_all_dispatched_commands_require_live_grant_before_dispatch(self) -> None:
        @contextlib.contextmanager
        def locked(*args, **kwargs):
            self.assertFalse(kwargs["create_state_root"])
            yield 9

        for command in (
            "prepare", "verify", "finish", "prepare-finalization", "finish-committed-resume",
            "live-resume", "absence-resume", "prepare-transition-proof", "state-publish",
            "retention-list", "retention-check", "retention-delete",
        ):
            options = [
                command, "--deploy-lock-fd", "9", "--execution-attempt", "a" * 32,
                "--execution-grant", "b" * 32, "--deadline-ns", "200",
            ]
            for revoked in (False, True):
                self.client.request.side_effect = (
                    self.supervisor.SupervisorError("private-canary") if revoked else None
                )
                with (
                    self.subTest(command=command, revoked=revoked),
                    mock.patch.object(helper, "_deploy_lock", locked),
                    mock.patch.object(helper, "_dispatch") as dispatch,
                    contextlib.redirect_stderr(io.StringIO()) as error,
                ):
                    self.assertEqual(1 if revoked else 0, helper.main(options))
                if revoked:
                    dispatch.assert_not_called()
                    self.assertEqual("RECOVERY_REQUIRED\n", error.getvalue())
                else:
                    dispatch.assert_called_once()
                self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_no_success_output_after_revocation_and_context_closes_after_failure(self) -> None:
        with (
            contextlib.redirect_stdout(io.StringIO()) as output,
            self.assertRaises(helper.ProviderError),
        ):
            with self.authority():
                self.revoke()
                helper._result(False, False, False, "committed")
        self.assertEqual("", output.getvalue())
        self.client.close.assert_called_once()
        self.assertIsNone(helper._EXECUTION_CHECK.get())

    def test_private_writes_recheck_between_each_syscall_and_never_resume_after_revocation(self) -> None:
        for descriptor_relative in (False, True):
            for stop in ("open", "write", "fsync", "fchown", "fchmod", "acl"):
                events = []
                self.client.request.side_effect = None

                def boundary(name, result=None):
                    def invoke(*args, **kwargs):
                        events.append(name)
                        if name == stop:
                            self.revoke()
                        return result
                    return invoke

                with self.subTest(relative=descriptor_relative, stop=stop), contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.multiple(
                        helper.os, O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                    ))
                    stack.enter_context(mock.patch.object(helper, "_check_ancestors"))
                    stack.enter_context(mock.patch.object(helper.os, "open", side_effect=boundary("open", 12)))
                    stack.enter_context(mock.patch.object(helper.os, "close", side_effect=boundary("close")))
                    stack.enter_context(mock.patch.object(helper.os, "write", side_effect=boundary("write", 7)))
                    for name in ("fsync", "fchown", "fchmod"):
                        stack.enter_context(mock.patch.object(
                            helper.os, name, side_effect=boundary(name), create=True,
                        ))
                    stack.enter_context(mock.patch.object(helper, "_acl_is_safe", side_effect=boundary("acl")))
                    with self.assertRaises(helper.ProviderError):
                        with self.authority():
                            if descriptor_relative:
                                helper._write_private_at(11, "snapshot", b"fixture", 0o600)
                            else:
                                helper._write_private("/private/snapshot", b"fixture", 0o600)
                order = ["open", "write", "fsync", "fchown", "fchmod", "acl"]
                self.assertEqual(order[:order.index(stop) + 1] + ["close"], events)

    def test_pipe_wait_polls_live_revocation_and_checks_again_before_read(self) -> None:
        stream = mock.Mock()
        stream.buffer.fileno.return_value = 12
        info = mock.Mock(st_mode=stat.S_IFIFO)
        for readable in (False, True):
            self.client.request.side_effect = None

            def waiting(read, write, error, seconds):
                self.assertLessEqual(seconds, 0.1)
                self.revoke()
                return ([12] if readable else [], [], [])

            with (
                self.subTest(readable=readable),
                mock.patch.object(helper.sys, "stdin", stream),
                mock.patch.object(helper.os, "fstat", return_value=info),
                mock.patch.object(helper.select, "select", side_effect=waiting) as poll,
                mock.patch.object(helper.os, "read") as read,
                self.assertRaises(helper.ProviderError),
            ):
                with self.authority():
                    helper._bounded_stdin(4096)
            poll.assert_called_once()
            read.assert_not_called()

    def test_rename_revalidates_after_boundary_before_calling_libc(self) -> None:
        renameat2 = mock.Mock(return_value=0)
        with (
            mock.patch.object(helper, "_rename_noreplace_boundary", side_effect=self.revoke),
            mock.patch.object(helper.ctypes, "CDLL", return_value=mock.Mock(renameat2=renameat2)),
            self.assertRaises(helper.ProviderError),
        ):
            with self.authority():
                helper._rename_noreplace(11, "temporary", "published")
        renameat2.assert_not_called()

    def test_terminal_publication_cannot_rename_after_revoked_temporary_write(self) -> None:
        for publish in (helper._publish_terminal_record, helper._publish_finalization_terminal):
            self.client.request.side_effect = None
            with (
                self.subTest(publish=publish.__name__),
                self.assertRaises(helper.ProviderError),
                self.authority(),
                mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
                mock.patch.object(helper, "_write_private_at", side_effect=self.revoke),
                mock.patch.object(helper.ctypes, "CDLL") as libc,
                mock.patch.object(helper.os, "fsync") as fsync,
            ):
                publish(11, finalization_witness())
            libc.assert_not_called()
            fsync.assert_not_called()

    def test_pointer_removal_revalidates_after_identity_read_and_before_directory_fsync(self) -> None:
        witness = finalization_witness()
        info = mock.Mock(
            st_dev=1, st_ino=2, st_uid=0, st_mode=stat.S_IFREG | 0o600,
            st_nlink=1, st_mtime_ns=3, st_ctime_ns=4,
        )
        for remove in (helper._unlink_finalizing_pointer, helper._remove_finalizing_pointer):
            for stop in ("stat", "unlink"):
                self.client.request.side_effect = None
                reads = 0

                def pointer_stat(name, **kwargs):
                    nonlocal reads
                    if name == ".provider-transaction.current":
                        reads += 1
                        if reads == 2 and stop == "stat":
                            self.revoke()
                    return info

                with self.subTest(remove=remove.__name__, stop=stop), contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.multiple(
                        helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                        O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                    ))
                    stack.enter_context(mock.patch.object(helper, "_open_deploy_state_root", return_value=11))
                    stack.enter_context(mock.patch.object(helper.os, "open", return_value=11))
                    stack.enter_context(mock.patch.object(helper.os, "close"))
                    stack.enter_context(mock.patch.object(helper.os, "stat", side_effect=pointer_stat))
                    stack.enter_context(mock.patch.object(helper.os, "fstat", return_value=info))
                    stack.enter_context(mock.patch.object(helper, "_marker", return_value=witness["pointer"]))
                    stack.enter_context(mock.patch.object(
                        helper, "_open_private_state_file_at",
                        return_value=(12, info, json.dumps(witness["pointer"]).encode()),
                    ))
                    unlink = stack.enter_context(mock.patch.object(helper.os, "unlink", side_effect=self.revoke))
                    fsync = stack.enter_context(mock.patch.object(helper.os, "fsync"))
                    with self.assertRaises(helper.ProviderError):
                        with self.authority():
                            remove("/state", witness["runKey"], witness)
                self.assertEqual(int(stop == "unlink"), unlink.call_count)
                fsync.assert_not_called()

    def test_quarantine_resume_revalidates_before_unlink_and_fsync(self) -> None:
        data = b"synthetic fixture"
        record = dict(
            finalization_witness(True)["transaction"]["entries"][0]["identity"],
            sha256=helper._finalization_digest(data),
        )
        info = mock.Mock(
            st_dev=record["device"], st_ino=record["inode"], st_uid=record["uid"],
            st_gid=record["gid"], st_mode=stat.S_IFREG | record["mode"],
            st_size=record["size"], st_mtime_ns=record["mtimeNs"], st_nlink=1,
        )
        entry = {
            "name": "identity.json", "quarantineName": ".provider-cleanup-fixture",
            "identity": record,
        }
        for stop in ("read", "unlink"):
            self.client.request.side_effect = None

            def file_stat(name, **kwargs):
                if name == entry["name"]:
                    raise FileNotFoundError
                return info

            def read(*args, **kwargs):
                if stop == "read":
                    self.revoke()
                return data

            with self.subTest(stop=stop), contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.multiple(
                    helper.os, O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0),
                    O_NONBLOCK=getattr(os, "O_NONBLOCK", 0), create=True,
                ))
                stack.enter_context(mock.patch.object(helper.os, "stat", side_effect=file_stat))
                stack.enter_context(mock.patch.object(helper.os, "fstat", return_value=info))
                stack.enter_context(mock.patch.object(helper.os, "open", return_value=12))
                stack.enter_context(mock.patch.object(helper.os, "close"))
                stack.enter_context(mock.patch.object(helper, "_acl_is_safe"))
                stack.enter_context(mock.patch.object(helper, "_read_fd_bounded", side_effect=read))
                unlink = stack.enter_context(mock.patch.object(helper.os, "unlink", side_effect=self.revoke))
                fsync = stack.enter_context(mock.patch.object(helper.os, "fsync"))
                with self.assertRaises(helper.ProviderError):
                    with self.authority():
                        helper._resume_quarantined_child(11, entry, link_count=1)
            self.assertEqual(int(stop == "unlink"), unlink.call_count)
            fsync.assert_not_called()


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux descriptor semantics")
class LinuxProviderDescriptorTests(unittest.TestCase):
    def test_directory_flock_contention_fails_without_waiting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            first = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY)
            second = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY)
            try:
                helper._lock_directory(first)
                with self.assertRaises(helper.ProviderError):
                    helper._lock_directory(second)
                os.close(first)
                first = None
                helper._lock_directory(second)
            finally:
                if first is not None:
                    os.close(first)
                os.close(second)

    def test_descriptor_record_rejects_path_replacement_after_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            original = directory / "snapshot"
            original.write_bytes(b"synthetic snapshot")
            original.chmod(0o600)
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            capture = helper._child_witness

            def replacing(fd, name, **kwargs):
                result = capture(fd, name, **kwargs)
                original.rename(directory / "old-snapshot")
                original.write_bytes(b"synthetic replacement")
                original.chmod(0o600)
                return result

            try:
                with (
                    mock.patch.object(helper, "_child_witness", side_effect=replacing),
                    self.assertRaises(helper.ProviderError),
                ):
                    helper._file_record(
                        directory_fd, "snapshot", uid=os.getuid(), gid=os.getgid(),
                    )
            finally:
                os.close(directory_fd)

    def test_quarantine_resume_ignores_only_rename_ctime_and_preserves_durable_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            publication = directory / "publication"
            durable = directory / "durable"
            publication.write_bytes(b"synthetic credential only")
            publication.chmod(0o440)
            os.link(publication, durable)
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                record = helper._file_record(
                    directory_fd, "publication", uid=os.getuid(), gid=os.getgid(),
                    mode=0o440, links=2,
                )
                kwargs = dict(
                    expected_identity=helper._finalization_expected_identity(record),
                    uid=os.getuid(), gid=os.getgid(), mode=0o440, link_count=2,
                    quarantine_name=".provider-cleanup-fixture-publication",
                    expected_data_digest=record["sha256"],
                    expected_stable_identity=helper._finalization_stable_identity(record),
                )
                with (
                    mock.patch.object(
                        helper.os, "unlink", side_effect=helper.ProviderError("RECOVERY_REQUIRED"),
                    ),
                    self.assertRaises(helper.ProviderError),
                ):
                    helper._witnessed_unlink(directory_fd, "publication", **kwargs)
                self.assertFalse(publication.exists())
                self.assertTrue((directory / kwargs["quarantine_name"]).exists())
                helper._witnessed_unlink(directory_fd, "publication", **kwargs)
                self.assertEqual(b"synthetic credential only", durable.read_bytes())
                self.assertEqual(1, durable.stat().st_nlink)
                self.assertEqual(["durable"], os.listdir(directory))
            finally:
                os.close(directory_fd)

    def test_extra_link_refuses_before_quarantine_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            original = directory / "snapshot"
            original.write_bytes(b"synthetic input")
            original.chmod(0o600)
            directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                record = helper._file_record(
                    directory_fd, "snapshot", uid=os.getuid(), gid=os.getgid(),
                )
                os.link(original, directory / "foreign-link")
                with self.assertRaises(helper.ProviderError):
                    helper._witnessed_unlink(
                        directory_fd, "snapshot",
                        expected_identity=helper._finalization_expected_identity(record),
                        uid=os.getuid(), gid=os.getgid(), mode=0o600, link_count=1,
                        quarantine_name=".provider-cleanup-fixture-snapshot",
                        expected_data_digest=record["sha256"],
                        expected_stable_identity=helper._finalization_stable_identity(record),
                    )
                self.assertEqual({"snapshot", "foreign-link"}, set(os.listdir(directory)))
            finally:
                os.close(directory_fd)

    def test_unclosed_stdin_pipe_expires_at_absolute_deadline(self) -> None:
        read_fd, write_fd = os.pipe()
        try:
            stream = mock.Mock()
            stream.buffer.fileno.return_value = read_fd
            with (
                mock.patch.object(helper.sys, "stdin", stream),
                self.assertRaises(helper.ProviderError),
            ):
                with helper._operation_deadline(time.monotonic_ns() + 20_000_000):
                    helper._bounded_stdin(4096)
        finally:
            os.close(read_fd)
            os.close(write_fd)


class ProviderCredentialTests(unittest.TestCase):
    def test_disabled_state_has_no_mount(self) -> None:
        enabled, values = helper._provider_state(inspection(False))
        present, read_only, source = helper._provider_mount(inspection(False), enabled)
        self.assertFalse(enabled)
        self.assertEqual("", values["APP_PUSH_CREDENTIALS_FILE"])
        self.assertEqual((False, False, None), (present, read_only, source))

    def test_enabled_state_requires_fixed_read_only_mount(self) -> None:
        enabled, _ = helper._provider_state(inspection())
        self.assertTrue(enabled)
        self.assertEqual(
            (True, True, helper.HOST_CREDENTIAL_PATH),
            helper._provider_mount(inspection(), enabled),
        )

    def test_unexpected_mount_is_rejected(self) -> None:
        value = inspection(False)
        value["Mounts"].append({"Type": "bind", "Destination": "/unexpected"})
        with self.assertRaises(helper.ProviderError) as error:
            helper._provider_mount(value, False)
        self.assertEqual("PROVIDER_STATE_INVALID", error.exception.category)

    def test_duplicate_environment_is_rejected(self) -> None:
        value = inspection(False)
        value["Config"]["Env"].append("APP_PUSH_PROVIDER_ENABLED=false")
        with self.assertRaises(helper.ProviderError):
            helper._provider_state(value)

    def test_alias_and_alternate_configuration_are_rejected(self) -> None:
        value = inspection(False)
        value["Config"]["Env"].append("APP-PUSH-DISPATCH-ENABLED=false")
        with self.assertRaises(helper.ProviderError):
            helper._provider_state(value)
        for alternate in (
            "SPRING_APPLICATION_JSON={}",
            "SPRING_CONFIG_NAME=evil",
            "spring.config.name=evil",
            "JAVA_TOOL_OPTIONS=-Dspring.application.json={}",
            "JAVA_TOOL_OPTIONS=-Dspring.config.name=evil",
            "JDK_JAVA_OPTIONS=-Dspring.config.import=evil",
            "_JAVA_OPTIONS=-Dspring.config.data.location=evil",
            "JAVA_TOOL_OPTIONS=-Dapp.push.provider.enabled=true",
        ):
            value = inspection(False)
            value["Config"]["Env"].append(alternate)
            with self.assertRaises(helper.ProviderError):
                helper._provider_state(value)

    def test_target_image_channels_are_checked_before_runtime_writers(self) -> None:
        image = inspection(False)
        image["Config"]["Entrypoint"] = ["java", "-jar", "app.jar"]
        helper._image_admission(image)
        writer_count = 0
        cases = (
            ("APP_PUSH_PROVIDER_ENABLED=false", "duplicate"),
            ("APP-PUSH-DISPATCH-ENABLED=false", "alias"),
            ("SPRING_CONFIG_NAME=evil", "alternate environment"),
            ("JAVA_TOOL_OPTIONS=-Dspring.config.name=evil", "alternate Java environment"),
        )
        for entry, label in cases:
            candidate = inspection(False)
            candidate["Config"]["Entrypoint"] = ["java", "-jar", "app.jar"]
            candidate["Config"]["Env"].append(entry)
            if label == "duplicate":
                candidate["Config"]["Env"].append(entry)
            try:
                helper._image_admission(candidate)
            except helper.ProviderError:
                pass
            else:
                writer_count += 1
                self.fail(f"{label} image admission reached a writer")
        for command in (
            ["java", "-Dapp.push.provider.enabled=true", "-jar", "app.jar"],
            ["java", "--spring.config.name=evil", "-jar", "app.jar"],
        ):
            candidate = inspection(False)
            candidate["Config"]["Entrypoint"] = command
            try:
                helper._image_admission(candidate)
            except helper.ProviderError:
                pass
            else:
                writer_count += 1
                self.fail("alternate command image admission reached a writer")
        self.assertEqual(0, writer_count)

    def test_explicit_blank_project_is_rejected(self) -> None:
        value = inspection(False)
        value["Config"]["Env"] = [
            item
            for item in value["Config"]["Env"]
            if not item.startswith("APP_PUSH_PROJECT_ID=")
        ]
        value["Config"]["Env"].append("APP_PUSH_PROJECT_ID=")
        with self.assertRaises(helper.ProviderError):
            helper._provider_state(value)

    def test_production_cli_has_no_filesystem_root_override(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                helper._parser().parse_args(["check", "--root", "/tmp"])

    def test_deploy_lock_fd_is_an_explicit_integer_option(self) -> None:
        args = helper._parser().parse_args(
            [
                "finish",
                "--run-key",
                "31885558214-1",
                "--deploy-lock-fd",
                "9",
            ]
        )
        self.assertEqual(9, args.deploy_lock_fd)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                helper._parser().parse_args(
                    [
                        "finish",
                        "--run-key",
                        "31885558214-1",
                        "--deploy-lock-fd",
                        "not-a-descriptor",
                    ]
                )

    def test_deploy_lock_mode_requires_a_regular_non_executable_safe_mode(self) -> None:
        for mode in (0o600, 0o640, 0o644):
            self.assertTrue(helper._deploy_lock_mode_is_safe(mode))
        for mode in (0o400, 0o660, 0o666, 0o700, 0o755):
            self.assertFalse(helper._deploy_lock_mode_is_safe(mode))

    def test_deterministic_quarantine_name_is_a_distinct_basename(self) -> None:
        self.assertEqual(
            ".provider-cleanup-run-identity",
            helper._validate_quarantine_name(
                "identity.json",
                ".provider-cleanup-run-identity",
            ),
        )
        for candidate in ("", ".", "..", "identity.json", "../escape", "a/b", "nul\x00"):
            with self.assertRaises(helper.ProviderError):
                helper._validate_quarantine_name("identity.json", candidate)

    def test_deploy_lock_fd_is_not_an_unlocked_fallback(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            status = helper.main(["check", "--deploy-lock-fd", "9"])
        self.assertEqual(1, status)

    def test_public_provider_operations_run_inside_the_requested_lock_context(self) -> None:
        events: list[tuple[str, int | None]] = []

        @contextlib.contextmanager
        def lock_context(
            state_root: str,
            inherited_fd: int | None,
            *,
            create_state_root: bool = False,
        ):
            self.assertEqual("/var/lib/meet-test-vps-deploy", state_root)
            events.append(("lock-enter", inherited_fd))
            try:
                yield
            finally:
                events.append(("lock-exit", inherited_fd))

        def dispatch(args) -> None:
            events.append(("dispatch", args.deploy_lock_fd))

        with (
            mock.patch.object(helper, "_deploy_lock", lock_context),
            mock.patch.object(helper, "_dispatch", dispatch),
        ):
            status = helper.main(
                [
                    "retention-check",
                    "--state-root",
                    "/var/lib/meet-test-vps-deploy",
                    "--deploy-lock-fd",
                    "9",
                ]
            )
        self.assertEqual(0, status)
        self.assertEqual(
            [("lock-enter", 9), ("dispatch", 9), ("lock-exit", 9)],
            events,
        )

    def test_direct_public_provider_operation_acquires_the_shared_lock(self) -> None:
        events: list[tuple[str, int | None]] = []

        @contextlib.contextmanager
        def lock_context(
            state_root: str,
            inherited_fd: int | None,
            *,
            create_state_root: bool = False,
        ):
            events.append(("lock-enter", inherited_fd))
            yield
            events.append(("lock-exit", inherited_fd))

        with (
            mock.patch.object(helper, "_deploy_lock", lock_context),
            mock.patch.object(
                helper,
                "_dispatch",
                side_effect=lambda args: events.append(("dispatch", args.deploy_lock_fd)),
            ),
        ):
            status = helper.main(["prepare", "--run-key", "31885558214-1"])
        self.assertEqual(0, status)
        self.assertEqual(
            [("lock-enter", None), ("dispatch", None), ("lock-exit", None)],
            events,
        )

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "O_DIRECTORY"),
        "Linux filesystem test",
    )
    def test_retention_allows_only_a_truly_absent_guard_without_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                self.assertIsNone(helper._timepad_retention_guard(str(root), root_fd, 9))
                os.mkdir(".timepad-bootstrap-fixture", dir_fd=root_fd)
                with self.assertRaises(helper.ProviderError):
                    helper._timepad_retention_guard(str(root), root_fd, 9)
            finally:
                os.close(root_fd)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "O_DIRECTORY"),
        "Linux filesystem test",
    )
    def test_retention_blocks_lost_malformed_and_nonterminal_guard_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "timepad-guard").mkdir()
            root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            module = helper._timepad_state_module()
            try:
                for reason in ("GUARD_STATE_LOST", "INVALID_INPUT", "STATE_PATH_UNSAFE"):
                    with self.subTest(reason=reason):
                        with mock.patch.object(
                            module,
                            "read_guard",
                            side_effect=module.GuardError(reason),
                        ) as read_guard:
                            with self.assertRaises(helper.ProviderError):
                                helper._timepad_retention_guard(str(root), root_fd, 9)
                        read_guard.assert_called_once_with(str(root), deploy_lock_fd=9)

                for phase in (
                    "READY",
                    "PREPARED",
                    "CUTOVER_POSSIBLE",
                    "RECOVERY_REQUIRED",
                    "FORWARD_RECOVERING",
                ):
                    with self.subTest(phase=phase):
                        with mock.patch.object(
                            module,
                            "read_guard",
                            return_value=(
                                {},
                                {
                                    "phase": phase,
                                    "ownedRun": "31885558214-1-final-deploy",
                                },
                            ),
                        ):
                            with self.assertRaises(helper.ProviderError):
                                helper._timepad_retention_guard(str(root), root_fd, 9)
            finally:
                os.close(root_fd)

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "O_DIRECTORY"),
        "Linux filesystem test",
    )
    def test_retention_protects_the_latest_terminal_run_and_rechecks_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "timepad-guard").mkdir()
            root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            module = helper._timepad_state_module()
            latest = "31885558214-2-final-deploy"
            try:
                with mock.patch.object(
                    module,
                    "read_guard",
                    return_value=(
                        {},
                        {"phase": "COMMITTED", "ownedRun": latest},
                    ),
                ) as read_guard:
                    guarded_run = helper._timepad_retention_guard(str(root), root_fd, 9)
                read_guard.assert_called_once_with(str(root), deploy_lock_fd=9)
                self.assertEqual(latest, guarded_run)
                self.assertTrue(
                    helper._retention_guard_protects_state(latest, guarded_run)
                )
                self.assertFalse(
                    helper._retention_guard_protects_state(
                        "31885558214-1-final-deploy",
                        guarded_run,
                    )
                )
                self.assertFalse(
                    helper._retention_guard_protects_state("older-run", None)
                )

                with mock.patch.object(
                    module,
                    "read_guard",
                    return_value=(
                        {},
                        {
                            "phase": "ROLLED_BACK",
                            "ownedRun": "31885558214-3-rollback-drill",
                        },
                    ),
                ):
                    rechecked_run = helper._timepad_retention_guard(str(root), root_fd, 9)
                self.assertNotEqual(guarded_run, rechecked_run)
                self.assertTrue(
                    helper._retention_guard_protects_state(
                        rechecked_run,
                        rechecked_run,
                    )
                )
            finally:
                os.close(root_fd)

    def test_retention_delete_lock_contention_stops_before_dispatch(self) -> None:
        events: list[str] = []

        @contextlib.contextmanager
        def contended_lock(
            state_root: str,
            inherited_fd: int | None,
            *,
            create_state_root: bool = False,
        ):
            events.append("lock-contended")
            raise helper.ProviderError("RECOVERY_REQUIRED")
            yield

        with (
            mock.patch.object(helper, "_deploy_lock", contended_lock),
            mock.patch.object(
                helper,
                "_dispatch",
                side_effect=lambda args: events.append("dispatch"),
            ),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            status = helper.main(
                [
                    "retention-delete",
                    "--retention-state",
                    "/var/lib/meet-test-vps-deploy/31885558214-1-final-deploy",
                ]
            )
        self.assertEqual(1, status)
        self.assertEqual(["lock-contended"], events)

    def test_finalization_witness_success_replay_and_immutable_publication(self) -> None:
        witness = finalization_witness()
        self.assertEqual(witness, helper._validate_finalization_witness(witness))
        encoded = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
        self.assertLessEqual(len(encoded), helper.MAX_FINALIZATION_BYTES)

        with (
            mock.patch.object(
                helper,
                "_read_child_file",
                side_effect=helper.ProviderError("RECOVERY_REQUIRED"),
            ),
            mock.patch.object(helper.os, "stat", side_effect=FileNotFoundError),
            mock.patch.object(helper, "_write_private_at") as write_private,
            mock.patch.object(helper, "_rename_noreplace") as rename,
            mock.patch.object(helper.os, "fsync") as fsync,
        ):
            helper._store_finalization_witness(17, encoded)
        write_private.assert_called_once_with(
            17,
            ".provider-finalization.tmp",
            encoded,
            0o600,
        )
        rename.assert_called_once_with(
            17,
            ".provider-finalization.tmp",
            "provider-finalization.json",
        )
        fsync.assert_called_once_with(17)

        with (
            mock.patch.object(
                helper,
                "_read_child_file",
                return_value=({}, encoded),
            ),
            mock.patch.object(helper, "_write_private_at") as write_private,
            mock.patch.object(helper, "_rename_noreplace") as rename,
            mock.patch.object(helper.os, "fsync") as fsync,
        ):
            helper._store_finalization_witness(17, encoded)
        write_private.assert_not_called()
        rename.assert_not_called()
        fsync.assert_not_called()

    def test_finalization_witness_rejects_failure_and_tampering(self) -> None:
        witness = finalization_witness()
        for path, replacement in (
            (("pointer", "phase"), "verifying"),
            (("terminal", "outcome"), "rolled-back"),
            (("commitWitnessDigest",), "x" * 64),
            (("providerEnabled",), True),
        ):
            modified = json.loads(json.dumps(witness))
            target = modified
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = replacement
            with self.subTest(path=path), self.assertRaises(helper.ProviderError):
                helper._validate_finalization_witness(modified)

        valid_encoded = json.dumps(
            witness,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        tampered_encoded = valid_encoded + b" "
        with (
            mock.patch.object(
                helper,
                "_read_child_file",
                return_value=({}, tampered_encoded),
            ),
            mock.patch.object(helper, "_write_private_at") as write_private,
            mock.patch.object(helper.os, "stat") as stat_call,
        ):
            with self.assertRaises(helper.ProviderError):
                helper._store_finalization_witness(17, valid_encoded)
        stat_call.assert_not_called()
        write_private.assert_not_called()

    def test_committed_finalization_commands_run_inside_the_shared_lock(self) -> None:
        events: list[tuple[str, int | None]] = []

        @contextlib.contextmanager
        def lock_context(
            state_root: str,
            inherited_fd: int | None,
            *,
            create_state_root: bool = False,
        ):
            events.append(("lock-enter", inherited_fd))
            yield inherited_fd if inherited_fd is not None else 27
            events.append(("lock-exit", inherited_fd))

        def dispatch(args) -> None:
            events.append(("dispatch", args.active_deploy_lock_fd))
            self.assertIn(
                args.command,
                {"prepare-finalization", "finish-committed-resume"},
            )
            self.assertEqual("final-deploy", args.state_kind)

        with (
            mock.patch.object(helper, "_deploy_lock", lock_context),
            mock.patch.object(helper, "_dispatch", dispatch),
        ):
            for command in ("prepare-finalization", "finish-committed-resume"):
                status = helper.main(
                    [
                        command,
                        "--run-key",
                        "31885558214-1",
                        "--state-kind",
                        "final-deploy",
                        "--deploy-lock-fd",
                        "9",
                    ]
                )
                self.assertEqual(0, status)
        self.assertEqual(
            [
                ("lock-enter", 9),
                ("dispatch", 9),
                ("lock-exit", 9),
                ("lock-enter", 9),
                ("dispatch", 9),
                ("lock-exit", 9),
            ],
            events,
        )

    def test_committed_finalization_lock_contention_stops_before_dispatch(self) -> None:
        events: list[str] = []

        @contextlib.contextmanager
        def contended_lock(
            state_root: str,
            inherited_fd: int | None,
            *,
            create_state_root: bool = False,
        ):
            events.append("lock-contended")
            raise helper.ProviderError("RECOVERY_REQUIRED")
            yield 9

        with (
            mock.patch.object(helper, "_deploy_lock", contended_lock),
            mock.patch.object(
                helper,
                "_dispatch",
                side_effect=lambda args: events.append("dispatch"),
            ),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            status = helper.main(
                [
                    "finish-committed-resume",
                    "--run-key",
                    "31885558214-1",
                    "--state-kind",
                    "final-deploy",
                    "--deploy-lock-fd",
                    "9",
                ]
            )
        self.assertEqual(1, status)
        self.assertEqual(["lock-contended"], events)

    def test_credential_shape_is_private_and_strict(self) -> None:
        valid = json.dumps(
            {
                "type": "service_account",
                "project_id": "meeting-1d258",
                "client_email": "fixture@example.invalid",
                "client_id": "fixture-id",
                "private_key_id": "fixture-key",
                "private_key": "-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----",
                "token_uri": "https://oauth2.example.invalid/token",
            }
        ).encode()
        helper._validate_credential(valid)
        with self.assertRaises(helper.ProviderError):
            helper._validate_credential(valid.replace(b"meeting-1d258", b"wrong-project"))
        with self.assertRaises(helper.ProviderError):
            helper._validate_credential(b'{"type":"service_account","type":"service_account"}')

    def test_bounded_json_rejects_depth_and_oversize(self) -> None:
        nested: object = {}
        for _ in range(helper.MAX_JSON_DEPTH + 2):
            nested = {"x": nested}
        with self.assertRaises(helper.ProviderError):
            helper._json(json.dumps(nested).encode())
        with self.assertRaises(helper.ProviderError):
            helper._bounded_stdin  # keep the public bound covered by the constant
            helper._json(b"[" + b"0" * (helper.MAX_INSPECTION_BYTES + 1) + b"]")

    def test_owner_marker_is_exact_and_typed(self) -> None:
        marker = helper._state_marker("31885558214-1", "rollback-drill")
        helper._parse_state_marker(marker, "31885558214-1", "rollback-drill")
        for value in (
            b'{"schemaVersion":true,"owner":"meet-test-vps-provider","runKey":"31885558214-1","stateKind":"rollback-drill"}',
            b'{"schemaVersion":1,"owner":"other","runKey":"31885558214-1","stateKind":"rollback-drill"}',
            b'{"schemaVersion":1,"owner":"meet-test-vps-provider","runKey":"31885558214-1","stateKind":"final-deploy"}',
            b'{"schemaVersion":1,"owner":"meet-test-vps-provider","runKey":"31885558214-1","stateKind":"rollback-drill","extra":1}',
            b'{"schemaVersion":1,"owner":"meet-test-vps-provider","runKey":"31885558214-1","stateKind":"rollback-drill","stateKind":"rollback-drill"}',
        ):
            with self.assertRaises(helper.ProviderError) as error:
                helper._parse_state_marker(value, "31885558214-1", "rollback-drill")
            self.assertEqual("RECOVERY_REQUIRED", error.exception.category)

    def test_transaction_integer_primitives_are_exact(self) -> None:
        valid = {
            "schemaVersion": 1,
            "predecessor": {
                "device": 1,
                "inode": 2,
                "mtimeNs": 3,
                "ctimeNs": 4,
            },
            "durable": {
                "device": 5,
                "inode": 6,
                "mtimeNs": 7,
                "ctimeNs": 8,
            },
        }
        helper._validate_identity(valid)
        malformed_schema = dict(valid, schemaVersion=True)
        with self.assertRaises(helper.ProviderError):
            helper._validate_identity(malformed_schema)
        for record_name in ("predecessor", "durable"):
            for field in ("device", "inode", "mtimeNs", "ctimeNs"):
                malformed = json.loads(json.dumps(valid))
                malformed[record_name][field] = True
                with self.assertRaises(helper.ProviderError):
                    helper._validate_identity(malformed)

    def test_state_names_are_numeric_and_canonical(self) -> None:
        self.assertEqual(
            ("31885558214-1", "rollback-drill"),
            helper._state_parts("31885558214-1-rollback-drill"),
        )
        with self.assertRaises(helper.ProviderError):
            helper._state_parts("run-key-final-deploy")

    def test_success_output_is_allowlisted(self) -> None:
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            helper._result(True, True, True, "verified")
        value = json.loads(stream.getvalue())
        self.assertEqual(
            {
                "schemaVersion",
                "providerEnabled",
                "credentialMountPresent",
                "credentialMountReadOnly",
                "outcome",
            },
            set(value),
        )
        self.assertNotIn("fixture@example.invalid", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
