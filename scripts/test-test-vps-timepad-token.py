#!/usr/bin/env python3
"""Hermetic root/Linux tests: fake provider and Docker, never real credentials."""

import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import textwrap
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    "timepad_token", Path(__file__).with_name("configure-test-vps-timepad-token.py"))
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
SECRET = b"fixture-token-NOT-A-REAL-SECRET_123"
BASE = (b"BACKEND_IMAGE=unchanged\nTIMEPAD_ENABLED=false\nINGESTION_ENABLED=false\n"
        b"OTHER_SECRET=preserve-this-exactly\nTIMEPAD_TOKEN=\n")


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.lock = self.state / ".deploy.lock"
        self.lock.write_bytes(b"")
        self.lock.chmod(0o600)
        self.env = self.root / ".env.production"
        self.env.write_bytes(BASE)
        self.env.chmod(0o600)
        self.provider = Mock(return_value={"provider_http": 200, "total": 12,
                                          "within_discovery_budget": True})
        self.runtime = Mock(return_value=("container-id", "start-time"))

    def tearDown(self):
        self.tmp.cleanup()

    def configure(self, token=SECRET):
        return tool.configure(self.env, self.state, token, self.runtime, self.provider)

    def assertUnchanged(self):
        self.assertEqual(self.env.read_bytes(), BASE)
        self.assertEqual(list(self.root.glob(".timepad-token-*")), [])

    def test_only_token_changes_and_runtime_is_not_restarted(self):
        result = self.configure()
        self.assertEqual(self.env.read_bytes(), BASE.replace(
            b"TIMEPAD_TOKEN=\n", b"TIMEPAD_TOKEN=" + SECRET + b"\n"))
        self.assertEqual(stat.S_IMODE(self.env.stat().st_mode), 0o600)
        self.provider.assert_called_once_with(SECRET.decode())
        self.assertEqual(self.runtime.call_count, 2)
        self.assertFalse(result["backend_restarted"])
        self.assertFalse(result["ingestion_enabled"])
        self.assertNotIn(SECRET.decode(), json.dumps(result))
        self.assertEqual(len(list(self.root.iterdir())), 2)

    def test_idempotent_reapply_does_not_replace_environment(self):
        self.configure()
        before = tool.identity(self.env.stat())
        self.configure()
        self.assertEqual(tool.identity(self.env.stat()), before)

    def test_append_missing_token_and_preserve_crlf(self):
        self.env.write_bytes(BASE.replace(b"TIMEPAD_TOKEN=\n", b"").replace(b"\n", b"\r\n"))
        self.configure()
        self.assertTrue(self.env.read_bytes().endswith(b"TIMEPAD_TOKEN=" + SECRET + b"\n"))
        self.assertIn(b"INGESTION_ENABLED=false\r\n", self.env.read_bytes())

    def test_bad_tokens_never_probe_or_write(self):
        for token in (b"", b"a\n", b"Bearer abc", b"$(oops)", b"quote'", b"x" * 4097,
                      b"\0", b"\xff", b"abc=def"):
            with self.subTest(token_length=len(token)):
                with self.assertRaises(tool.Rejected):
                    self.configure(token)
                self.assertUnchanged()
        self.provider.assert_not_called()

    def test_provider_failure_preserves_previous_token_and_all_files(self):
        self.provider.side_effect = tool.Rejected("provider_http_403")
        with self.assertRaisesRegex(tool.Rejected, "provider_http_403"):
            self.configure()
        self.assertUnchanged()

    def test_duplicate_assignment_or_enabled_feed_never_probe(self):
        for data in (BASE + b"TIMEPAD_TOKEN=duplicate\n",
                     BASE + b"export TIMEPAD_TOKEN=ambiguous\n",
                     BASE + b" TIMEPAD_TOKEN = ambiguous\n",
                     BASE.replace(b"TIMEPAD_ENABLED=false", b"TIMEPAD_ENABLED=true"),
                     BASE.replace(b"INGESTION_ENABLED=false", b"INGESTION_ENABLED=true")):
            self.env.write_bytes(data)
            with self.assertRaises(tool.Rejected):
                self.configure()
            self.assertEqual(self.env.read_bytes(), data)
        self.provider.assert_not_called()

    def test_oversized_file_rejected_without_provider_access(self):
        self.env.write_bytes(BASE + b"#" * tool.MAX_BYTES)
        with self.assertRaisesRegex(tool.Rejected, "file_budget"):
            self.configure()
        self.provider.assert_not_called()

    def test_unsafe_lock_and_symlinked_state_rejected(self):
        self.lock.chmod(0o666)
        with self.assertRaises(tool.Rejected):
            self.configure()
        self.lock.chmod(0o600)
        alias = self.root / "state-alias"
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(OSError):
            tool.configure(self.env, alias, SECRET, self.runtime, self.provider)
        self.provider.assert_not_called()

    def test_existing_public_readable_empty_lock_is_preserved(self):
        self.lock.chmod(0o644)
        before = tool.identity(self.lock.stat())
        self.configure()
        self.assertEqual(tool.identity(self.lock.stat()), before)
        self.provider.assert_called_once_with(SECRET.decode())
        self.assertEqual(stat.S_IMODE(self.env.stat().st_mode), 0o600)

    def test_nonempty_lock_never_probes_or_writes(self):
        for mode in (0o600, 0o644):
            with self.subTest(mode=mode):
                self.lock.chmod(mode)
                self.lock.write_bytes(b"unexpected")
                with self.assertRaisesRegex(tool.Rejected, "nonempty_deployment_lock"):
                    self.configure()
                self.assertUnchanged()
        self.provider.assert_not_called()

    def test_symlink_hardlink_or_public_environment_rejected(self):
        original = self.env.read_bytes()
        self.env.chmod(0o644)
        with self.assertRaises(tool.Rejected):
            self.configure()
        self.env.chmod(0o600)
        alias = self.root / "alias"
        os.link(self.env, alias)
        with self.assertRaises(tool.Rejected):
            self.configure()
        alias.unlink()
        self.env.rename(alias)
        self.env.symlink_to(alias)
        with self.assertRaises(OSError):
            self.configure()
        self.assertEqual(alias.read_bytes(), original)
        self.provider.assert_not_called()

    def test_unsafe_ancestor_rejected(self):
        self.root.chmod(0o777)
        with self.assertRaises(tool.Rejected):
            self.configure()
        self.root.chmod(0o700)
        self.provider.assert_not_called()

    def test_unresolved_pointer_including_broken_symlink_rejected(self):
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            pointer = self.state / name
            pointer.symlink_to("missing")
            with self.assertRaisesRegex(tool.Rejected, "unresolved_transaction"):
                self.configure()
            pointer.unlink()
        self.assertUnchanged()
        self.provider.assert_not_called()

    def test_lock_busy_never_probes(self):
        with self.lock.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.configure()
        self.provider.assert_not_called()
        self.assertUnchanged()

    def test_concurrent_environment_or_runtime_change_rejected(self):
        def modify(_):
            self.env.write_bytes(BASE + b"EXTERNAL_CHANGE=preserve\n")
            return {}
        self.provider.side_effect = modify
        with self.assertRaisesRegex(tool.Rejected, "environment_changed"):
            self.configure()
        self.assertTrue(self.env.read_bytes().endswith(b"EXTERNAL_CHANGE=preserve\n"))
        self.env.write_bytes(BASE)
        self.provider.side_effect = None
        self.runtime.side_effect = [("id", "old"), ("id", "new")]
        with self.assertRaisesRegex(tool.Rejected, "runtime_changed"):
            self.configure()
        self.assertUnchanged()

    def test_failed_replace_preserves_environment_and_removes_temp(self):
        with patch.object(tool.os, "replace", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.configure()
        self.assertUnchanged()

    def test_stored_but_directory_sync_failure_is_explicit(self):
        original = tool.os.fsync
        def fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fixture")
            return original(fd)
        with patch.object(tool.os, "fsync", side_effect=fsync):
            with self.assertRaisesRegex(tool.Rejected, "token_stored_durability_uncertain"):
                self.configure()
        self.assertIn(SECRET, self.env.read_bytes())

    def test_cli_failure_never_echoes_secret(self):
        for error in (tool.Rejected("provider_http_403"), ValueError(SECRET.decode())):
            with patch.object(tool.sys, "argv", ["tool"]), \
                    patch.object(tool.sys, "stdin", Mock(buffer=io.BytesIO(SECRET))), \
                    patch.object(tool, "configure", side_effect=error), \
                    patch.object(tool.sys, "stdout", new_callable=io.StringIO) as output:
                self.assertEqual(tool.main(), 1)
                self.assertNotIn(SECRET.decode(), output.getvalue())
                self.assertIn("error", json.loads(output.getvalue()))

    def test_runtime_failure_never_calls_provider(self):
        self.runtime.side_effect = tool.Rejected("unexpected_runtime")
        with self.assertRaisesRegex(tool.Rejected, "unexpected_runtime"):
            self.configure()
        self.provider.assert_not_called()
        self.assertUnchanged()


class ProbeTests(unittest.TestCase):
    def connection(self, status=200, body=b'{"total":1,"values":[{}]}',
                   content_type="application/json", encoding="identity"):
        response = Mock(status=status)
        response.getheader.side_effect = lambda key, default=None: {
            "Content-Type": content_type, "Content-Encoding": encoding}.get(key, default)
        response.read.return_value = body
        connection = Mock()
        connection.getresponse.return_value = response
        return connection

    def test_fixed_tls_origin_auth_header_and_one_bounded_request(self):
        connection = self.connection()
        with patch.object(tool.http.client, "HTTPSConnection", return_value=connection) as factory:
            result = tool.probe(SECRET.decode())
        factory.assert_called_once_with("api.timepad.ru", timeout=3)
        connection.request.assert_called_once()
        args, kwargs = connection.request.call_args
        self.assertEqual(args[0], "GET")
        self.assertTrue(args[1].startswith("/v1/events.json?"))
        self.assertIn("sort=%2Bstarts_at", args[1])
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer " + SECRET.decode())
        connection.getresponse.return_value.read.assert_called_once_with(tool.MAX_BYTES + 1)
        connection.close.assert_called_once()
        self.assertEqual(result["total"], 1)

    def test_rejected_status_type_size_encoding_and_schema(self):
        cases = [self.connection(status=403), self.connection(status=302),
                 self.connection(content_type="text/html"),
                 self.connection(encoding="gzip"),
                 self.connection(body=b"x" * (tool.MAX_BYTES + 1)),
                 self.connection(body=b'{"total":true,"values":[]}'),
                 self.connection(body=b'{"total":1,"values":[]}'),
                 self.connection(body=b'{"total":0,"total":0,"values":[]}')]
        for connection in cases:
            with self.subTest(), patch.object(tool.http.client, "HTTPSConnection",
                                             return_value=connection):
                with self.assertRaises(tool.Rejected):
                    tool.probe(SECRET.decode())
                connection.close.assert_called_once()

    def test_over_budget_is_reported_without_claiming_import(self):
        body = json.dumps({"total":501, "values":[{}] * 100}).encode()
        with patch.object(tool.http.client, "HTTPSConnection",
                          return_value=self.connection(body=body)):
            self.assertFalse(tool.probe(SECRET.decode())["within_discovery_budget"])


class WorkflowTests(unittest.TestCase):
    def test_manual_secret_stdin_and_shared_lock_routing(self):
        text = (Path(__file__).resolve().parents[1] / ".github/workflows/"
                "configure-test-vps-timepad-token.yml").read_text()
        for required in ("workflow_dispatch:", "github.ref == 'refs/heads/dev'",
                         "name: test-vps", "test-vps-deploy-${{ github.repository }}",
                         "TIMEPAD_TOKEN: ${{ secrets.TIMEPAD_TOKEN }}",
                         "printf '%s' \"$TIMEPAD_TOKEN\" | timeout 60s ssh",
                         "StrictHostKeyChecking yes", "sha256sum --status -c -"):
            self.assertIn(required, text)
        for forbidden in ("push:", "schedule:", "set -x", "StrictHostKeyChecking no",
                          "docker compose", "upload-artifact"):
            self.assertNotIn(forbidden, text)
        self.assertEqual(text.count("${{ secrets.TIMEPAD_TOKEN }}"), 1)


class RuntimeTests(unittest.TestCase):
    ID = "a" * 64

    def backend(self):
        return {"Id": self.ID, "Config": {"Image": tool.IMAGE, "Labels": {
            "com.docker.compose.project": "meet-production",
            "com.docker.compose.service": "backend"}, "Env": [
            "TIMEPAD_ENABLED=false", "INGESTION_ENABLED=false"]},
                "State": {"Running": True, "Health": {"Status": "healthy"},
                          "StartedAt": "fixture"}}

    def test_expected_runtime_returns_stable_identity(self):
        with patch.object(tool.subprocess, "run", side_effect=[
            Mock(stdout=(self.ID + "\n").encode()),
            Mock(stdout=json.dumps([self.backend()]).encode()),
        ]):
            self.assertEqual(tool.runtime(), (self.ID, "fixture"))

    def test_extra_backend_or_wrong_image_rejected(self):
        with patch.object(tool.subprocess, "run", return_value=Mock(stdout=b"a\nb\n")):
            with self.assertRaisesRegex(tool.Rejected, "single_backend_required"):
                tool.runtime()
        backend = self.backend()
        backend["Config"]["Image"] = "unapproved-image"
        with patch.object(tool.subprocess, "run", side_effect=[
            Mock(stdout=(self.ID + "\n").encode()), Mock(stdout=json.dumps([backend]).encode()),
        ]):
            with self.assertRaisesRegex(tool.Rejected, "unexpected_runtime"):
                tool.runtime()

    def test_counted_container_identity_and_project_must_match(self):
        for change in ("id", "project", "service"):
            backend = self.backend()
            if change == "id":
                backend["Id"] = "b" * 64
            else:
                key = "com.docker.compose." + change
                backend["Config"]["Labels"][key] = "different"
            with self.subTest(change=change), patch.object(tool.subprocess, "run", side_effect=[
                Mock(stdout=(self.ID + "\n").encode()), Mock(stdout=json.dumps([backend]).encode()),
            ]) as run:
                with self.assertRaisesRegex(tool.Rejected, "unexpected_runtime"):
                    tool.runtime()
                self.assertEqual(run.call_args_list[1].args[0], ["docker", "inspect", self.ID])


class StagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        text = (Path(__file__).resolve().parents[1] / ".github/workflows/"
                "configure-test-vps-timepad-token.yml").read_text()
        code = text.split("<<'PY_STAGE'\n", 1)[1].split("\n          PY_STAGE", 1)[0]
        namespace = {"__name__": "hermetic_staging_test"}
        exec(compile(textwrap.dedent(code), "workflow_staging", "exec"), namespace)
        self.stage = namespace["make_stage"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_actual_workflow_staging_is_root_private(self):
        stage = Path(self.stage(self.root))
        self.assertEqual(stage.parent, self.root)
        self.assertEqual(stat.S_IMODE(stage.stat().st_mode), 0o700)
        self.assertEqual(stage.stat().st_uid, 0)
        self.assertEqual(list(stage.iterdir()), [])

    def test_unsafe_root_or_ancestor_rejected_before_staging(self):
        for mode in (0o777, 0o775):
            self.root.chmod(mode)
            with self.assertRaisesRegex(RuntimeError, "unsafe staging permissions"):
                self.stage(self.root)
            self.assertEqual(list(self.root.iterdir()), [])
        self.root.chmod(0o700)
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            self.stage(alias)


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Tests require Linux root and use isolated /root fixtures only.")
    unittest.main()
