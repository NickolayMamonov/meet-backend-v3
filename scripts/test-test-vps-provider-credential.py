#!/usr/bin/env python3
"""Unit tests for the release-first private provider helper.

These tests stay unprivileged and exercise parser/admission contracts.  Linux
ownership, ACL, no-follow and container readability proof belongs to the
filesystem/runtime harness.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import importlib.util
import json
import pathlib
import sys
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

INDEX_BYTES = (ROOT / "fixtures" / "selected-platform" / "image-index.json"
               ).read_bytes().removesuffix(b"\n")
INDEX_SHA256 = "1f2c56da34fa905553739f79bf91647d0087ec72159efc40828ba91622033d4b"
if hashlib.sha256(INDEX_BYTES).hexdigest() != INDEX_SHA256:
    raise AssertionError("fixture must reproduce the exact release index bytes without terminal LF")
INDEX_REF = (
    "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + INDEX_SHA256
)


def target_proof(engine_image_id: str | None = None) -> dict:
    return {
        "indexRef": INDEX_REF,
        "rawIndexBase64": base64.b64encode(INDEX_BYTES).decode("ascii"),
        "selectedPlatform": "linux/amd64",
        "selectedManifestDigest": helper.FORWARD_TARGET["amd64ManifestDigest"],
        "engineImageId": engine_image_id or helper.FORWARD_TARGET["indexDigest"],
    }


def target_image(engine_image_id: str | None = None) -> dict:
    value = inspection(False)
    value["Id"] = engine_image_id or helper.FORWARD_TARGET["indexDigest"]
    value["Architecture"] = "amd64"
    value["Os"] = "linux"
    value["RepoDigests"] = [INDEX_REF]
    value["Config"].update({
        "User": "10001:10001",
        "Entrypoint": ["java", "-jar", "app.jar"],
        "Labels": {
            "org.opencontainers.image.source": "https://github.com/NickolayMamonov/meet-backend-v3",
            "org.opencontainers.image.revision": helper.FORWARD_TARGET["source"],
            "org.opencontainers.image.version": helper.FORWARD_TARGET["version"],
        },
    })
    return value


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


class ProviderCredentialTests(unittest.TestCase):
    def test_selected_platform_proof_binds_index_platform_repo_and_engine_id(self) -> None:
        image_id = helper.FORWARD_TARGET["indexDigest"]
        proof = target_proof(image_id)
        image = target_image(image_id)

        helper._validate_target_image_proof(proof, image, forward=True)

        # Classic Docker may expose a config-derived Engine ID; it is not the
        # index or selected-manifest digest and must remain opaque to this proof.
        classic_id = "sha256:" + "b" * 64
        classic_proof = target_proof(classic_id)
        helper._validate_target_image_proof(
            classic_proof, target_image(classic_id), forward=True
        )
        self.assertNotEqual(classic_id, proof["indexRef"].split("@", 1)[1])
        self.assertNotEqual(classic_id, proof["selectedManifestDigest"])

    def test_selected_platform_proof_rejects_substitutions(self) -> None:
        mutations = (
            ("extra field", lambda proof, image: proof.update(extra="ignored")),
            ("index reference digest", lambda proof, image: proof.update(
                indexRef=INDEX_REF[:-1] + "0")),
            ("selected platform", lambda proof, image: proof.update(selectedPlatform="linux/arm64")),
            ("selected child", lambda proof, image: proof.update(
                selectedManifestDigest="sha256:" + "9" * 64)),
            ("engine ID", lambda proof, image: proof.update(engineImageId="sha256:" + "a" * 64)),
            ("raw bytes", lambda proof, image: proof.update(rawIndexBase64=base64.b64encode(
                INDEX_BYTES + b" ").decode("ascii"))),
            ("oversized proof bytes", lambda proof, image: proof.update(
                rawIndexBase64="A" * ((helper.MAX_TARGET_INDEX_BYTES + 16) * 2))),
            ("noncanonical base64", lambda proof, image: proof.update(
                rawIndexBase64=proof["rawIndexBase64"] + "\n")),
            ("missing RepoDigest", lambda proof, image: image.update(RepoDigests=[])),
            ("wrong index RepoDigest", lambda proof, image: image.update(RepoDigests=[
                INDEX_REF[:-1] + "0"])),
            ("child RepoDigest", lambda proof, image: image.update(RepoDigests=[
                "ghcr.io/nickolaymamonov/meet-backend-v3@" +
                helper.FORWARD_TARGET["amd64ManifestDigest"]])),
            ("wrong OS", lambda proof, image: image.update(Os="windows")),
            ("wrong architecture", lambda proof, image: image.update(Architecture="arm64")),
            ("wrong user", lambda proof, image: image["Config"].update(User="0")),
            ("wrong revision", lambda proof, image: image["Config"]["Labels"].update(
                {"org.opencontainers.image.revision": "f" * 40})),
            ("wrongly typed revision", lambda proof, image: image["Config"]["Labels"].update(
                {"org.opencontainers.image.revision": 123})),
            ("wrong version", lambda proof, image: image["Config"]["Labels"].update(
                {"org.opencontainers.image.version": "1.5.2"})),
            ("wrongly typed version", lambda proof, image: image["Config"]["Labels"].update(
                {"org.opencontainers.image.version": ["1.6.0"]})),
        )
        for label, mutate in mutations:
            with self.subTest(label=label):
                proof = target_proof()
                image = target_image()
                mutate(proof, image)
                with self.assertRaises(helper.ProviderError):
                    helper._validate_target_image_proof(proof, image, forward=True)

    def test_selected_platform_proof_rejects_duplicate_selected_descriptors(self) -> None:
        index = json.loads(INDEX_BYTES)
        selected = next(
            item for item in index["manifests"]
            if item.get("platform") == {"architecture": "amd64", "os": "linux"}
        )
        index["manifests"].append(selected)
        raw = json.dumps(index, separators=(",", ":")).encode()
        digest = "sha256:" + hashlib.sha256(raw).hexdigest()
        proof = target_proof()
        proof.update(
            indexRef="ghcr.io/nickolaymamonov/meet-backend-v3@" + digest,
            rawIndexBase64=base64.b64encode(raw).decode("ascii"),
        )
        image = target_image()
        image["RepoDigests"] = [proof["indexRef"]]

        with self.assertRaises(helper.ProviderError):
            helper._validate_target_image_proof(proof, image)

    def test_selected_platform_proof_rejects_invalid_or_foreign_descriptors(self) -> None:
        selected_index = next(
            index for index, descriptor in enumerate(
                json.loads(INDEX_BYTES)["manifests"]
            )
            if descriptor.get("platform") == {"architecture": "amd64", "os": "linux"}
        )
        cases = (
            ("variant", lambda descriptor: descriptor["platform"].update(variant="v3")),
            ("foreign os", lambda descriptor: descriptor["platform"].update(os="windows")),
            ("foreign architecture",
             lambda descriptor: descriptor["platform"].update(architecture="arm64")),
            ("bad size", lambda descriptor: descriptor.update(size=0)),
            ("bad media type", lambda descriptor: descriptor.update(mediaType="text/plain")),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                index = json.loads(INDEX_BYTES)
                mutate(index["manifests"][selected_index])
                raw = json.dumps(index, separators=(",", ":")).encode()
                digest = "sha256:" + hashlib.sha256(raw).hexdigest()
                proof = target_proof()
                proof.update(
                    indexRef="ghcr.io/nickolaymamonov/meet-backend-v3@" + digest,
                    rawIndexBase64=base64.b64encode(raw).decode("ascii"),
                )
                image = target_image()
                image["RepoDigests"] = [proof["indexRef"]]

                with self.assertRaises(helper.ProviderError):
                    helper._validate_target_image_proof(proof, image)

    def test_check_image_envelope_is_strict_and_accepts_engine_id_semantics(self) -> None:
        proof = target_proof()
        image = target_image()
        request = {"imageInspect": [image], "targetImageProof": proof}
        with contextlib.redirect_stdout(io.StringIO()), mock.patch(
            "sys.stdin", mock.Mock(buffer=io.BytesIO(json.dumps(request).encode()))
        ):
            self.assertEqual(0, helper.main(["check-image"]))
        for request in (
            {"imageInspect": [image]},
            {"imageInspect": [image], "targetImageProof": proof, "platformImage": [image]},
            {"imageInspect": [], "targetImageProof": proof},
            {"imageInspect": [image, image], "targetImageProof": proof},
        ):
            with self.subTest(request=request.keys()):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
                    io.StringIO()
                ), mock.patch(
                    "sys.stdin",
                    mock.Mock(buffer=io.BytesIO(json.dumps(request).encode())),
                ):
                    self.assertNotEqual(0, helper.main(["check-image"]))

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

    def test_proof_hash_marker_types_fail_with_recovery_category(self) -> None:
        run_key = "55555555555-1"
        owner = json.loads(helper._state_marker(
            run_key, "final-deploy", target_image_proof=b"{}"))
        pointer = {
            "schemaVersion": 2, "runKey": run_key, "phase": "verifying",
            "providerEnabled": False, "durableDisposition": "none",
            "targetImageProofSha256": "0" * 64,
        }
        for malformed in (None, True, 1, [], {}, "g" * 64):
            with self.subTest(value=malformed):
                owner["targetImageProofSha256"] = malformed
                pointer["targetImageProofSha256"] = malformed
                with self.assertRaises(helper.ProviderError) as rejected:
                    helper._parse_state_marker(
                        json.dumps(owner).encode(), run_key, "final-deploy")
                self.assertEqual(rejected.exception.category, "RECOVERY_REQUIRED")
                with mock.patch.object(
                    helper, "_read_private", return_value=json.dumps(pointer).encode()
                ), self.assertRaises(helper.ProviderError) as rejected:
                    helper._marker("/unused", run_key)
                self.assertEqual(rejected.exception.category, "RECOVERY_REQUIRED")

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
