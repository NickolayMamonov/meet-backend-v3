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
    )
    if phase != "PREPARED":
        current.update(
            phase=phase, containerId="f" * 64, configHash="0" * 64,
            latestAttemptId=current["incidentId"] + ":1",
        )
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
    return module, contract, origin, current, envelope


class LiveResumeTests(unittest.TestCase):
    def authority(self, context: tuple) -> tuple:
        module, contract, origin, current, envelope = context
        with mock.patch.object(module, "_read_input", return_value=json.dumps(contract).encode()):
            return helper._live_resume_authority(
                envelope, module=module, origin=origin, current=current,
                run_key="31885558214-1", state_kind="final-deploy",
            )

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
                    mock.patch.object(helper, "_timepad_current", return_value=(object(), origin, current)),
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

            with (
                self.subTest(names=names),
                mock.patch.multiple(
                    helper.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                    O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                ),
                mock.patch.object(helper, "_read_finalization_witness", return_value=(witness, data)),
                mock.patch.object(helper, "_controller_commit_witness", return_value=(
                    commit, commit_data, helper._finalization_digest(commit_data),
                )),
                mock.patch.object(helper, "_file_record", side_effect=file_record),
                mock.patch.object(helper.os, "stat"),
                mock.patch.object(helper, "_marker", return_value=witness["pointer"]),
                mock.patch.object(helper.os.path, "lexists", return_value=True),
                mock.patch.object(helper.os, "open", side_effect=[13, 14]),
                mock.patch.object(helper.os, "close"),
                mock.patch.object(helper.os, "fstat"),
                mock.patch.object(helper, "_lock_directory"),
                mock.patch.object(helper, "_directory_record", side_effect=[
                    witness["transaction"]["directory"], witness["transaction"]["parent"],
                ]),
                mock.patch.object(helper, "_iter_directory_fd_names", return_value=names),
                mock.patch.object(helper, "_open_regular", return_value=(15, info, credential_data)),
                mock.patch.object(helper, "_validate_credential"),
                mock.patch.object(helper.os, "unlink") as unlink,
                mock.patch.object(helper.os, "write") as write,
                mock.patch.object(helper.os, "fsync") as fsync,
            ):
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
