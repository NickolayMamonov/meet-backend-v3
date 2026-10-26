#!/usr/bin/env python3
"""Hermetic Linux/root fixtures; no live Docker, SSH, provider or credentials."""

import sys

sys.dont_write_bytecode = True

import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
SPEC = importlib.util.spec_from_file_location(
    "locationiq_config", Path(__file__).with_name("configure-test-vps-locationiq.py"))
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
KEY = b"MOCK-NOT-A-REAL-KEY_123"
BASE = b"OTHER_SECRET=keep-exactly\nTIMEPAD_ENABLED=true\nINGESTION_ENABLED=true\n"
CONTAINER = "a" * 64


def record(env=None):
    return {"Id": CONTAINER, "Config": {
        "Labels": {"com.docker.compose.project": "meet-production",
                   "com.docker.compose.service": "backend"},
        "Env": env or [], "Entrypoint": ["java", "-jar", "app.jar"], "Cmd": None},
        "State": {"Running": True, "Health": {"Status": "healthy"}, "StartedAt": "same"}}


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        (self.state / ".deploy.lock").write_bytes(b"")
        (self.state / ".deploy.lock").chmod(0o600)
        self.env = self.root / ".env.production"
        self.env.write_bytes(BASE)
        self.env.chmod(0o600)
        self.runtime = Mock(return_value=(CONTAINER, "same"))
        # Every configuration fixture denies accidental subprocess/network use.
        self.process = patch.object(tool.subprocess, "Popen",
                                    side_effect=AssertionError("unexpected subprocess"))
        self.process.start()

    def tearDown(self):
        self.process.stop()
        self.assertEqual(list(self.root.glob(".locationiq-off-*")), [])
        self.tmp.cleanup()

    def configure(self, key=KEY):
        return tool.configure(self.env, self.state, key, self.runtime)

    def test_atomic_off_and_unrelated_bytes_private_owner(self):
        result = self.configure()
        self.assertEqual(self.env.read_bytes(), BASE + b"LOCATIONIQ_KEY=" + KEY
                         + b"\nGEOCODER_ENABLED=false\n")
        self.assertEqual(stat.S_IMODE(self.env.stat().st_mode), 0o600)
        self.assertEqual((self.env.stat().st_uid, self.env.stat().st_gid), (0, 0))
        self.assertFalse(result["backend_restarted"])
        self.assertFalse(result["persistent_geocoder_enabled"])
        self.assertEqual(self.runtime.call_count, 3)

    def test_empty_identical_missing_key_and_flags_crlf(self):
        for key_line in (b"", b"LOCATIONIQ_KEY=\r\n", b"LOCATIONIQ_KEY=" + KEY + b"\r\n"):
            for flag in (b"", b"GEOCODER_ENABLED=true\r\n", b"GEOCODER_ENABLED=false\r\n"):
                before = BASE.replace(b"\n", b"\r\n") + key_line + flag
                self.env.write_bytes(before)
                self.configure()
                expected = BASE.replace(b"\n", b"\r\n")
                if key_line:
                    expected += b"LOCATIONIQ_KEY=" + KEY + b"\r\n"
                if flag:
                    expected += b"GEOCODER_ENABLED=false\r\n"
                if not key_line:
                    expected += b"LOCATIONIQ_KEY=" + KEY + b"\r\n"
                if not flag:
                    expected += b"GEOCODER_ENABLED=false\r\n"
                self.assertEqual(self.env.read_bytes(), expected)
                before_stat = self.env.stat()
                self.configure()
                self.assertEqual(tool.identity(before_stat), tool.identity(self.env.stat()))

    def test_rejections_preserve_all_bytes(self):
        invalid = (
            BASE + b"LOCATIONIQ_KEY=other\n", BASE + b"GEOCODER_ENABLED=\n",
            BASE + b"GEOCODER_ENABLED=TRUE\n",
            BASE + b"GEOCODER_ENABLED=false\nGEOCODER_ENABLED=false\n",
            BASE + b"LOCATIONIQ_KEY=\nLOCATIONIQ_KEY=\n",
            BASE + b"export LOCATIONIQ_KEY=x\n", BASE + b" LOCATIONIQ_KEY=x\n",
            BASE + b"GEOCODER_ENABLED =false\n", BASE + b"X=$HOME\n",
            BASE + b"X=\0\n", BASE + b"X=\tbad\n", BASE[:-1],
            BASE + b"SPRING_APPLICATION_JSON={}\n",
            BASE + b"APP_GEOCODER_ENABLED=true\n",
            BASE + b"_JAVA_OPTIONS=-Dapp.geocoder.enabled=true\n",
            BASE + b"app_geocoder_enabled=true\n",
            BASE + b"geocoder_enabled=false\n",
            BASE + b"SPRING_CONFIG_IMPORT=optional:file:/other\n",
            BASE + b"JAVA_TOOL_OPTIONS=-Dapp.geocoder.enabled=true\n")
        for before in invalid:
            self.env.write_bytes(before)
            with self.assertRaises(tool.Rejected):
                self.configure()
            self.assertEqual(self.env.read_bytes(), before)
        for name in ("app.geocoder.enabled", "app-geocoder-enabled",
                     "spring.config.import", "spring.application.json",
                     "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"):
            before = BASE + name.encode() + b"=true\n"
            self.env.write_bytes(before)
            with self.subTest(name=name):
                with self.assertRaises(tool.Rejected):
                    self.configure()
                self.assertEqual(self.env.read_bytes(), before)

    def test_key_input_budgets(self):
        for raw in (b"", b"a\n", b"a=b", b"a" * 4097, b"$x", b" a", b"\xff", b"a\0"):
            with self.assertRaises(tool.Rejected):
                self.configure(raw)
            self.assertEqual(self.env.read_bytes(), BASE)
        self.assertEqual(tool.validate_key(b"a" * 4096), "a" * 4096)

    def test_lock_and_unresolved_transaction(self):
        fd = os.open(self.state / ".deploy.lock", os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.configure()
        finally:
            os.close(fd)
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            marker = self.state / name
            marker.symlink_to(self.root / "absent")
            with self.assertRaisesRegex(tool.Rejected, "unresolved_transaction"):
                self.configure()
            marker.unlink()
        self.assertEqual(self.env.read_bytes(), BASE)

    def test_file_trust_and_ancestors(self):
        self.env.chmod(0o644)
        with self.assertRaises(tool.Rejected):
            self.configure()
        self.env.chmod(0o600)
        self.root.chmod(0o777)
        with self.assertRaises(tool.Rejected):
            self.configure()
        self.root.chmod(0o700)
        target = self.root / "target"
        self.env.rename(target)
        self.env.symlink_to(target)
        with self.assertRaises(OSError):
            self.configure()
        self.env.unlink()
        target.rename(self.env)
        with patch("test_vps_file_trust.os.listxattr",
                   return_value=["system.posix_acl_access"]):
            with self.assertRaisesRegex(tool.Rejected, "unexpected_acl"):
                self.configure()
        alias = self.root / "hardlink"
        os.link(self.env, alias)
        with self.assertRaises(tool.Rejected):
            self.configure()
        alias.unlink()

    def test_runtime_changes_before_and_after_publication(self):
        self.runtime.side_effect = [(CONTAINER, "same"), ("different", "same")]
        with self.assertRaisesRegex(tool.Rejected, "^runtime_changed$"):
            self.configure()
        self.assertEqual(self.env.read_bytes(), BASE)
        self.runtime.side_effect = [(CONTAINER, "same"), (CONTAINER, "same"),
                                    ("different", "same")]
        with self.assertRaisesRegex(tool.Rejected, "configuration_published_durability_uncertain"):
            self.configure()
        self.assertIn(b"GEOCODER_ENABLED=false\n", self.env.read_bytes())

    def test_environment_race_prevents_overwrite(self):
        def race():
            self.env.write_bytes(BASE + b"OPERATOR=changed\n")
            return (CONTAINER, "same")
        self.runtime.side_effect = race
        with self.assertRaisesRegex(tool.Rejected, "environment_changed"):
            self.configure()
        self.assertEqual(self.env.read_bytes(), BASE + b"OPERATOR=changed\n")

    def test_failure_before_publish_and_parent_fsync_uncertainty(self):
        with patch.object(tool.os, "replace", side_effect=OSError("fake")):
            with self.assertRaises(OSError):
                self.configure()
        self.assertEqual(self.env.read_bytes(), BASE)
        actual = os.fsync
        def fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fake directory durability failure")
            actual(fd)
        with patch.object(tool.os, "fsync", side_effect=fsync):
            with self.assertRaisesRegex(tool.Rejected, "configuration_published_durability_uncertain"):
                self.configure()
        self.assertIn(b"GEOCODER_ENABLED=false\n", self.env.read_bytes())

    def test_alarm_at_replace_is_reported_as_published_uncertainty(self):
        replace = os.replace
        def publish_then_alarm(*args, **kwargs):
            replace(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGALRM)
        previous = signal.signal(signal.SIGALRM, tool.deadline)
        try:
            with patch.object(tool.os, "replace", side_effect=publish_then_alarm):
                with self.assertRaisesRegex(
                        tool.Rejected, "configuration_published_durability_uncertain"):
                    self.configure()
            self.assertIn(b"GEOCODER_ENABLED=false\n", self.env.read_bytes())
        finally:
            signal.signal(signal.SIGALRM, previous)


class RuntimeTests(unittest.TestCase):
    def test_inspections_pin_local_daemon_despite_poisoned_contexts(self):
        # A real child models Docker's endpoint precedence without invoking Docker.
        script = """
import json, os, pathlib, sys
context = os.environ.get('DOCKER_CONTEXT')
host = os.environ.get('DOCKER_HOST')
config = pathlib.Path(os.environ.get('DOCKER_CONFIG', os.environ['HOME'] + '/.docker'))
persisted = json.loads((config / 'config.json').read_text()) if (config / 'config.json').exists() else {}
endpoint = context or host or persisted.get('currentContext', 'default')
assert endpoint == 'unix:///var/run/docker.sock'
assert 'DOCKER_CONTEXT' not in os.environ and 'DOCKER_CONFIG' not in os.environ
assert 'DOCKER_TLS_VERIFY' not in os.environ and 'DOCKER_CERT_PATH' not in os.environ
print('local-only')
"""
        with tempfile.TemporaryDirectory(dir="/root") as tmp:
            root = Path(tmp)
            config = root / ".docker"
            config.mkdir()
            (config / "config.json").write_text('{"currentContext":"remote-poison"}')
            # Substitute only HOME to expose an actual poisoned persisted config.
            controlled = dict(tool.CHILD_ENV, HOME=str(root))
            poisoned = {"HOME": str(root), "DOCKER_CONTEXT": "remote-inherited",
                        "DOCKER_HOST": "tcp://remote:2375", "DOCKER_CONFIG": str(config),
                        "DOCKER_TLS_VERIFY": "1", "DOCKER_CERT_PATH": "/poison"}
            with patch.dict(os.environ, poisoned), patch.object(tool, "CHILD_ENV", controlled):
                self.assertEqual(tool.command([sys.executable, "-c", script]), b"local-only\n")

    def test_all_runtime_inspections_use_controlled_environment(self):
        popen = subprocess.Popen
        environments = []
        def child(arguments, **kwargs):
            environments.append(kwargs["env"])
            output = (CONTAINER + "\n") if arguments[1] == "ps" else json.dumps([record()])
            return popen([sys.executable, "-c", "import sys; sys.stdout.write(" + repr(output) + ")"],
                         **kwargs)
        with patch.dict(os.environ, {"DOCKER_CONTEXT": "remote", "HOME": "/poison",
                                    "DOCKER_HOST": "tcp://remote:2375"}), \
                patch.object(tool.subprocess, "Popen", side_effect=child):
            self.assertEqual(tool.runtime(), (CONTAINER, "same"))
        self.assertEqual(environments, [tool.CHILD_ENV, tool.CHILD_ENV])
        self.assertEqual(tool.CHILD_ENV["DOCKER_HOST"], "unix:///var/run/docker.sock")
        self.assertEqual(set(tool.CHILD_ENV), {"PATH", "LC_ALL", "HOME",
                                             "PYTHONDONTWRITEBYTECODE", "DOCKER_HOST"})

    def runtime(self, backend):
        with patch.object(tool, "command", side_effect=[
                (CONTAINER + "\n").encode(), json.dumps([backend]).encode()]) as command:
            result = tool.runtime()
            self.assertEqual(command.call_args_list[0].args[0],
                             ["docker", "ps", "--no-trunc", "-q", "--filter",
                              "label=com.docker.compose.service=backend"])
            self.assertEqual(command.call_args_list[1].args[0], ["docker", "inspect", CONTAINER])
            return result

    def test_effective_default_true_and_nonblank_means_active_without_probe(self):
        for env in (["LOCATIONIQ_KEY=x"], ["GEOCODER_ENABLED=true", "LOCATIONIQ_KEY=x"]):
            with self.assertRaisesRegex(tool.Rejected, "active_usable_geocoder"):
                self.runtime(record(env))
        for env in ([], ["LOCATIONIQ_KEY= "], ["GEOCODER_ENABLED=true"],
                    ["GEOCODER_ENABLED=false", "LOCATIONIQ_KEY=x"],
                    ["JAVA_TOOL_OPTIONS=" + tool.DEFAULT_JAVA_OPTIONS]):
            self.assertEqual(self.runtime(record(env)), (CONTAINER, "same"))

    def test_ambiguity_and_wrong_runtime(self):
        for env in (["GEOCODER_ENABLED="], ["GEOCODER_ENABLED=TRUE"],
                    ["LOCATIONIQ_KEY=x", "LOCATIONIQ_KEY=x"],
                    ["APP_GEOCODER_ENABLED=true"], ["SPRING_APPLICATION_JSON={}"],
                    ["JAVA_TOOL_OPTIONS=-Dapp.geocoder.enabled=true"]):
            with self.assertRaises(tool.Rejected):
                self.runtime(record(env))
        for name in ("_JAVA_OPTIONS", "app.geocoder.enabled", "app-geocoder-enabled",
                     "app_geocoder_enabled", "APP_GEOCODER_APIKEY",
                     "spring.config.import", "SPRING_CONFIG_NAME",
                     "spring.application.json", "geocoder_enabled"):
            with self.subTest(name=name):
                with self.assertRaises(tool.Rejected):
                    self.runtime(record([name + "=true"]))
        for field, value in (("Running", False), ("Health", {"Status": "unhealthy"})):
            backend = record()
            backend["State"][field] = value
            with self.assertRaises(tool.Rejected):
                self.runtime(backend)
        backend = record()
        backend["Config"]["Cmd"] = ["--app.geocoder.enabled=true"]
        with self.assertRaises(tool.Rejected):
            self.runtime(backend)

    def test_command_deadline_budget_and_nonzero(self):
        with self.assertRaisesRegex(tool.Rejected, "runtime_command_failed"):
            tool.command([sys.executable, "-c", "raise SystemExit(3)"])
        with self.assertRaisesRegex(tool.Rejected, "runtime_budget"):
            tool.command([sys.executable, "-c",
                          "import sys; sys.stdout.buffer.write(b'x'*1048577)"])
        with patch.object(tool.time, "monotonic", side_effect=[0, 11]):
            with self.assertRaisesRegex(tool.Rejected, "runtime_deadline"):
                tool.command([sys.executable, "-c", "import time; time.sleep(20)"])

    def test_main_safe_output_deadline_and_input_cap(self):
        output = io.StringIO()
        stdin = Mock(buffer=io.BytesIO(KEY))
        with patch.object(tool.sys, "stdin", stdin), patch.object(tool, "configure",
                side_effect=tool.Rejected("key_conflict")) as configure, \
                contextlib.redirect_stdout(output):
            self.assertEqual(tool.main(), 1)
        self.assertNotIn(KEY.decode(), output.getvalue())
        self.assertIn("key_conflict", output.getvalue())
        self.assertEqual(configure.call_args.args[2], KEY)
        with self.assertRaisesRegex(tool.Rejected, "deadline"):
            tool.deadline(signal.SIGALRM, None)
        output = io.StringIO()
        stdin = Mock(buffer=io.BytesIO(b"x" * 5000))
        with patch.object(tool.sys, "stdin", stdin), patch.object(tool, "configure",
                side_effect=OSError(KEY.decode())) as configure, \
                contextlib.redirect_stdout(output):
            self.assertEqual(tool.main(), 1)
        self.assertEqual(len(configure.call_args.args[2]), tool.MAX_KEY + 1)
        self.assertNotIn(KEY.decode(), output.getvalue())
        self.assertIn("configuration_or_runtime_failed", output.getvalue())

    def test_no_root_bytecode_in_isolated_import_or_child(self):
        with tempfile.TemporaryDirectory(dir="/root") as temporary:
            root = Path(temporary)
            for name in ("configure-test-vps-locationiq.py", "test_vps_file_trust.py"):
                (root / name).write_bytes(Path(__file__).with_name(name).read_bytes())
            # Explicitly remove inherited bytecode suppression: helper must protect itself.
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            result = subprocess.run(
                [sys.executable, str(root / "configure-test-vps-locationiq.py"), "invalid"],
                env=environment, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(list(root.rglob("*.pyc")))
            self.assertFalse(list(root.rglob("__pycache__")))


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Requires Linux root; isolated /root fixtures only.")
    unittest.main()
