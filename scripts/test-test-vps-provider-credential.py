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
import pathlib
import sys
import unittest

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
