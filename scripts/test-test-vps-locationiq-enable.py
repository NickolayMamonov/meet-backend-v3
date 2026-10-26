#!/usr/bin/env python3
"""Hermetic Linux/root activation fixtures. Docker/Compose/SSH are mocks only."""

import sys

sys.dont_write_bytecode = True

import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import tempfile
import unittest
from unittest.mock import Mock, patch

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
SPEC = importlib.util.spec_from_file_location(
    "locationiq_enable", Path(__file__).with_name("enable-test-vps-locationiq.py"))
tool = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tool
SPEC.loader.exec_module(tool)
APPROVED = tool.Approved("a" * 40, "sha256:" + "b" * 64, "sha256:" + "c" * 64, "1.6.0", "123-1")
KEY = "MOCK-KEY-NEVER-A-REAL-SECRET"
OLD, NEW, POSTGRES = "d" * 64, "e" * 64, "f" * 64
OFF_HASH, ON_HASH = "0" * 64, "1" * 64
WRAPPER = ["up", "-d", "--no-deps", "--no-build", "--pull", "never",
           "--force-recreate", "--wait", "--wait-timeout", "180", "backend"]


def write(path, data):
    path.write_bytes(data)
    path.chmod(0o600)


def image():
    return {"Id": APPROVED.image_id, "Config": {"User": "10001:10001",
            "Env": ["PATH=/fixed", "JAVA_TOOL_OPTIONS=" + tool.off.DEFAULT_JAVA_OPTIONS],
            "Labels": {"org.opencontainers.image.revision": APPROVED.source,
                       "org.opencontainers.image.version": APPROVED.version,
                       "org.opencontainers.image.source": tool.SOURCE}}}


class FakeCommands:
    def __init__(self, fixture):
        self.fixture = fixture
        self.log = []
        self.stopping = False
        self.recreated = False
        self.stopped = False
        self.failure = None
        self.stop_failure = False
        self.stop_still_running = False
        self.group_unresolved = False
        self.clock_value = 0
        self.image = image()
        self.runtime_override = {}
        self.render_drift = False
        self.post_render_hash_drift = False
        self.post_verify_failure = False

    def remaining(self, cap):
        return cap

    def begin_stop(self):
        if not self.stopping:
            self.log.append(("begin_stop",))
            self.stopping = True

    def reap(self):
        self.log.append(("reap",))
        if self.group_unresolved:
            raise tool.Rejected("group_unresolved")

    def model(self, env_path):
        values = tool.env_file(Path(env_path).read_bytes())
        if self.render_drift and Path(env_path) != self.fixture.env:
            values["TIMEPAD_ENABLED"] = "false"
        return {"name": "meet-production", "services": {
            "backend": {"image": APPROVED.image, "environment": values},
            "postgres": {"image": "unchanged"}}}

    def backend(self):
        flag = "true" if self.recreated else "false"
        values = tool.env_file(self.fixture.base)
        values["GEOCODER_ENABLED"] = flag
        actual = dict(item.split("=", 1) for item in self.image["Config"]["Env"])
        actual.update(values)
        labels = dict(self.image["Config"]["Labels"])
        labels.update({"com.docker.compose.project": "meet-production",
                       "com.docker.compose.service": "backend",
                       "com.docker.compose.config-hash": ON_HASH if self.recreated else OFF_HASH})
        if self.recreated:
            labels["com.docker.compose.replace"] = OLD
        record = {"Id": NEW if self.recreated else OLD, "Image": APPROVED.image_id,
                  "Config": {"Image": APPROVED.image, "User": "10001:10001",
                             "Env": [name + "=" + value for name, value in actual.items()],
                             "Labels": labels, "Entrypoint": ["java", "-jar", "app.jar"], "Cmd": None,
                             "Hostname": "new" if self.recreated else "old"},
                  "State": {"Running": True, "Health": {"Status": "healthy"}},
                  "HostConfig": {"ReadonlyRootfs": True, "RestartPolicy": {"Name": "unless-stopped"},
                                 "LogConfig": {"Type": "local"}, "Memory": 1024,
                                 "CapDrop": ["ALL"], "SecurityOpt": ["no-new-privileges:true"],
                                 "Tmpfs": {"/tmp": ""}},
                  "Mounts": [{"Type": "volume", "Destination": "/data/uploads", "Name": "meet-production_uploads_data"}],
                  "NetworkSettings": {"Ports": {"8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}}}
        record.update(copy.deepcopy(self.runtime_override))
        if self.recreated and self.post_verify_failure:
            record["State"]["Health"]["Status"] = "unhealthy"
        return record

    def postgres(self):
        return {"Id": POSTGRES, "Image": "sha256:postgres", "Config": {
            "Labels": {"com.docker.compose.project": "meet-production",
                       "com.docker.compose.service": "postgres"}}, "HostConfig": {},
            "State": {"Running": True, "Health": {"Status": "healthy"}},
            "Mounts": [{"Destination": "/var/lib/postgresql/data",
                        "Name": "meet-production_postgres_data"}],
            "NetworkSettings": {"Ports": {"5432/tcp": None}}}

    def run(self, arguments, cap=10, stdin=None, extra_env=None):
        self.log.append((list(arguments), cap, stdin, extra_env))
        if arguments[:3] == ["docker", "image", "inspect"]:
            return json.dumps([self.image]).encode()
        if arguments[:2] == ["docker", "ps"]:
            if "label=com.docker.compose.service=postgres" in arguments:
                return (POSTGRES + "\n").encode()
            return b"" if self.stopped else ((NEW if self.recreated else OLD) + "\n").encode()
        if arguments[:2] == ["docker", "inspect"]:
            record = self.postgres() if arguments[2] == POSTGRES else self.backend()
            return json.dumps([record]).encode()
        if arguments[:2] == ["docker", "compose"]:
            env_path = arguments[arguments.index("--env-file") + 1]
            if stdin:
                override = json.loads(stdin)
                assert override == {"services": {"backend": {"env_file": [env_path]}}}
                assert "config" in arguments
            model = self.model(env_path)
            if arguments[-2:] == ["--format", "json"]:
                return json.dumps(model).encode()
            if arguments[-2:] == ["--hash", "backend"]:
                flag = model["services"]["backend"]["environment"]["GEOCODER_ENABLED"]
                if self.post_render_hash_drift and Path(env_path) == self.fixture.env and flag == "true":
                    return ("backend " + "9" * 64 + "\n").encode()
                return ("backend " + (ON_HASH if flag == "true" else OFF_HASH) + "\n").encode()
        if arguments[:1] == ["bash"]:
            assert Path(arguments[1]) == self.fixture.stage / "production-compose.sh"
            assert extra_env == {"PRODUCTION_ROOT": str(self.fixture.root),
                                 "PRODUCTION_STATE_DIR": str(self.fixture.runtime)}
            if arguments[2:] == WRAPPER:
                assert b"GEOCODER_ENABLED=true\n" in self.fixture.env.read_bytes()
                self.recreated = True
                if self.failure:
                    raise tool.Rejected(self.failure)
                return b""
            if arguments[2:] == ["stop", "-t", "10", "backend"]:
                assert any(item == ("reap",) for item in self.log)
                if self.stop_failure:
                    raise tool.Rejected("stop_failed")
                self.stopped = not self.stop_still_running
                return b""
        raise AssertionError("unexpected command shape")


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.signals = {number: signal.getsignal(number) for number in tool.SIGNALS}
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.home = Path(self.tmp.name)
        self.root, self.state, self.runtime, self.stage = [self.home / name
                                                        for name in ("root", "state", "runtime", "stage")]
        for path in (self.root, self.state, self.runtime, self.stage):
            path.mkdir(mode=0o700)
        self.base = (f"BACKEND_IMAGE={APPROVED.image}\nBACKEND_REVISION={APPROVED.source}\n"
                     f"BACKEND_VERSION={APPROVED.version}\nLOCATIONIQ_KEY={KEY}\n"
                     "GEOCODER_ENABLED=false\nTIMEPAD_ENABLED=true\nINGESTION_ENABLED=true\n").encode()
        self.env = self.root / ".env.production"
        write(self.env, self.base)
        write(self.state / ".deploy.lock", b"")
        self.deployment = self.state / (APPROVED.run_key + "-final-deploy")
        self.deployment.mkdir(mode=0o700)
        write(self.deployment / "terminal.json", json.dumps({
            "schemaVersion": 1, "runKey": APPROVED.run_key, "outcome": "committed"}).encode())
        write(self.deployment / "config.env.target", self.base)
        for active, saved in (("active-compose.yml", "config.base-compose.yml"),
                              ("active-runtime.override.yml", "target-runtime.override.yml")):
            write(self.runtime / active, b"fixture reviewed compose\n")
            write(self.deployment / saved, b"fixture reviewed compose\n")
        for name in ("production-compose.sh", "enable-test-vps-locationiq.py",
                     "configure-test-vps-locationiq.py", "test_vps_file_trust.py"):
            write(self.stage / name, Path(__file__).with_name(name).read_bytes())
        self.commands = FakeCommands(self)
        self.activation = tool.Activation(APPROVED, root=self.root, state=self.state,
                                          runtime=self.runtime, stage=self.stage, commands=self.commands)
        self.subprocess = patch.object(tool.subprocess, "Popen",
                                       side_effect=AssertionError("real command forbidden"))
        self.subprocess.start()

    def tearDown(self):
        self.subprocess.stop()
        for number, handler in self.signals.items():
            signal.signal(number, handler)
        signal.setitimer(signal.ITIMER_REAL, 0)
        self.tmp.cleanup()

    def calls(self, action):
        return [item for item in self.commands.log if isinstance(item[0], list) and action in item[0]]

    def rejected(self):
        result = self.activation.execute()
        self.assertEqual(result, {"outcome": "rejected", "published": False, "stop": "not_attempted"})
        self.assertEqual(self.env.read_bytes(), self.base)
        self.assertFalse(self.commands.recreated)
        self.assertFalse(self.calls("stop"))
        self.assertFalse(list(self.root.glob(".locationiq-enable-*")))

    def test_success_exact_tuple_render_hash_change_one_recreate(self):
        result = self.activation.execute()
        self.assertEqual(result, {"outcome": "committed", "published": True, "stop": "not_attempted"})
        self.assertEqual(self.env.read_bytes(),
                         self.base.replace(b"GEOCODER_ENABLED=false", b"GEOCODER_ENABLED=true"))
        self.assertEqual(len(self.calls("up")), 1)
        self.assertFalse(self.calls("stop"))
        self.assertFalse(list(self.root.glob(".locationiq-enable-*")))
        self.assertTrue(self.activation.committed)

    def test_bad_tuple_formats(self):
        values = list(APPROVED.__dict__.values())
        for index, invalid in enumerate(("A" * 40, "tag", "../image", "01.2.3", "../1-1")):
            altered = values[:]
            altered[index] = invalid
            with self.assertRaises(tool.Rejected):
                tool.Approved(*altered)

    def test_wrong_image_or_source_reject_before_true(self):
        self.commands.image["Id"] = "sha256:" + "9" * 64
        self.rejected()

    def test_terminal_and_snapshot_admission(self):
        write(self.deployment / "terminal.json", b'{"schemaVersion":1,"outcome":"rolled-back","runKey":"123-1"}')
        self.rejected()
        write(self.deployment / "terminal.json", b'{"schemaVersion":1,"outcome":"committed","runKey":"123-1"}')
        write(self.deployment / "config.env.target", self.base.replace(APPROVED.source.encode(), b"8" * 40))
        self.rejected()

    def test_snapshot_release_only_and_unrelated_key_material_not_interpreted(self):
        write(self.deployment / "config.env.target",
              self.base + b"UNRELATED_OLD_FORMAT='retained value'\n")
        self.assertEqual(self.activation.execute()["outcome"], "committed")

    def test_off_key_alias_and_duplicate_rejections(self):
        for before in (self.base.replace(b"GEOCODER_ENABLED=false\n", b""),
                       self.base.replace(b"GEOCODER_ENABLED=false", b"GEOCODER_ENABLED=true"),
                       self.base.replace(KEY.encode(), b""),
                       self.base + b"_JAVA_OPTIONS=-Dapp.geocoder.enabled=true\n",
                       self.base + b"GEOCODER_ENABLED=false\n"):
            write(self.env, before)
            result = self.activation.execute()
            self.assertEqual(result["outcome"], "rejected")
            self.assertEqual(self.env.read_bytes(), before)
            self.assertFalse(self.commands.recreated)

    def test_live_key_or_off_mismatch_reject(self):
        config = self.commands.backend()["Config"]
        config["Env"] = [entry.replace(KEY, "different") for entry in config["Env"]]
        self.commands.runtime_override["Config"] = config
        self.rejected()

    def test_unsafe_file_active_config_and_transactions_reject(self):
        self.env.chmod(0o644)
        self.rejected()
        self.env.chmod(0o600)
        write(self.runtime / "active-compose.yml", b"changed")
        self.rejected()
        write(self.runtime / "active-compose.yml", b"fixture reviewed compose\n")
        (self.state / ".provider-transaction.current").symlink_to(self.home / "absent")
        self.rejected()

    def test_recreate_failure_reaped_before_single_stop_and_verified(self):
        self.commands.failure = "command_failed"
        result = self.activation.execute()
        self.assertEqual(result["outcome"], "manual_intervention_required")
        self.assertTrue(result["published"])
        self.assertEqual(result["stop"], "verified_stopped")
        self.assertEqual(len(self.calls("up")), 1)
        self.assertEqual(len(self.calls("stop")), 1)
        order = [item[0] for item in self.commands.log]
        self.assertLess(order.index("reap"), order.index(self.calls("stop")[0][0]))
        self.assertIn(b"GEOCODER_ENABLED=true\n", self.env.read_bytes())

    def test_stop_completion_not_stopped_and_failed_stop(self):
        self.commands.failure = "command_deadline"
        self.commands.stop_still_running = True
        self.assertEqual(self.activation.execute()["stop"], "unknown")
        self.assertEqual(len(self.calls("stop")), 1)

    def test_failed_stop_is_not_claimed_stopped(self):
        self.commands.failure = "command_failed"
        self.commands.stop_failure = True
        self.assertEqual(self.activation.execute()["stop"], "unknown")
        self.assertEqual(len(self.calls("stop")), 1)

    def test_render_unrelated_drift_rejects_before_publication(self):
        self.commands.render_drift = True
        self.rejected()

    def test_postpublication_hash_drift_stops_before_recreate(self):
        self.commands.post_render_hash_drift = True
        result = self.activation.execute()
        self.assertEqual(result["stop"], "verified_stopped")
        self.assertFalse(self.commands.recreated)
        self.assertIn(b"GEOCODER_ENABLED=true", self.env.read_bytes())

    def test_health_verification_failure_stops_no_retry(self):
        self.commands.post_verify_failure = True
        self.assertEqual(self.activation.execute()["stop"], "verified_stopped")
        self.assertEqual(len(self.calls("up")), 1)
        self.assertEqual(len(self.calls("stop")), 1)

    def test_unresolved_group_does_not_race_stop(self):
        self.commands.failure = "command_deadline"
        self.commands.group_unresolved = True
        result = self.activation.execute()
        self.assertEqual(result["stop"], "unknown")
        self.assertFalse(self.calls("stop"))

    def test_after_publish_fsync_failure_stops_no_restore(self):
        fsync = os.fsync
        def fail_parent(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("fixture")
            fsync(fd)
        with patch.object(tool.os, "fsync", side_effect=fail_parent):
            result = self.activation.execute()
        self.assertEqual(result["stop"], "verified_stopped")
        self.assertIn(b"GEOCODER_ENABLED=true\n", self.env.read_bytes())
        self.assertFalse(self.calls("up"))

    def test_prepublication_temp_failure_unchanged(self):
        with patch.object(tool.os, "fsync", side_effect=OSError("fixture")):
            self.rejected()

    def test_signal_brackets_rename_and_repeated_signals_do_not_reenter(self):
        replace = os.replace
        def interrupted(_number, _frame):
            raise tool.Rejected("fixture_signal")
        for number in tool.SIGNALS:
            signal.signal(number, interrupted)
        def publish(*args, **kwargs):
            blocked = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            self.assertTrue(tool.SIGNALS <= blocked)
            replace(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
        run = self.commands.run
        def repeated(arguments, **kwargs):
            if arguments[:1] == ["bash"] and "stop" in arguments:
                for number in tool.SIGNALS:
                    os.kill(os.getpid(), number)
            return run(arguments, **kwargs)
        with patch.object(tool.os, "replace", side_effect=publish), \
                patch.object(self.commands, "run", side_effect=repeated):
            result = self.activation.execute()
        self.assertEqual(result["stop"], "verified_stopped")
        self.assertTrue(result["published"])
        self.assertEqual(self.commands.log.count(("begin_stop",)), 1)
        self.assertEqual(len(self.calls("stop")), 1)

    def test_helper_cleanup_failure_after_recreate_stops_under_lock(self):
        with patch.object(self.activation, "cleanup", side_effect=OSError("fixture cleanup")):
            result = self.activation.execute()
        self.assertEqual(result["outcome"], "manual_intervention_required")
        self.assertFalse(self.activation.committed)
        self.assertEqual(len(self.calls("stop")), 1)

    def test_environment_race_before_publication_is_not_overwritten(self):
        unchanged = self.activation.unchanged
        def race():
            self.env.write_bytes(self.base + b"OPERATOR=changed\n")
            unchanged()
        with patch.object(self.activation, "unchanged", side_effect=race):
            result = self.activation.execute()
        self.assertFalse(result["published"])
        self.assertEqual(self.env.read_bytes(), self.base + b"OPERATOR=changed\n")
        self.assertFalse(self.commands.recreated)

    def test_helper_cleanup_is_before_commit_and_under_lock(self):
        clean = self.activation.cleanup
        def check():
            self.assertFalse(self.activation.committed)
            import fcntl
            fd = os.open(self.state / ".deploy.lock", os.O_RDONLY)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(fd)
            clean()
        with patch.object(self.activation, "cleanup", side_effect=check):
            self.assertEqual(self.activation.execute()["outcome"], "committed")

    def test_no_root_bytecode(self):
        self.assertFalse(list(self.stage.rglob("*.pyc")))
        self.assertFalse(list(self.stage.rglob("__pycache__")))


class BudgetTests(unittest.TestCase):
    def test_absolute_budget_and_stop_not_reset(self):
        clock = Mock(return_value=100)
        commands = tool.Commands(clock)
        self.assertEqual((commands.end, commands.phase_end), (400, 370))
        clock.return_value = 365
        self.assertEqual(commands.remaining(10), 5)
        commands.begin_stop()
        self.assertEqual(commands.phase_end, 395)
        clock.return_value = 390
        commands.begin_stop()
        self.assertEqual(commands.phase_end, 395)
        self.assertEqual(commands.remaining(20), 5)
        clock.return_value = 396
        with self.assertRaises(tool.Rejected):
            commands.remaining(1)

    def test_subprocess_controlled_environment_no_inherited_redirects(self):
        commands = tool.Commands()
        child = Mock(pid=9999999, stdout=Mock(), stdin=None)
        child.wait.return_value = 0
        child.stdout.fileno.return_value = 1
        selector = Mock()
        selector.__enter__ = Mock(return_value=selector)
        selector.__exit__ = Mock(return_value=False)
        selector.select.return_value = [(None, None)]
        with patch.dict(os.environ, {"PRODUCTION_ROOT": "/bad", "RUNTIME_BASE_COMPOSE": "/bad",
                                    "MEE_SMTP_FAKE_REMOTE": "true", "_JAVA_OPTIONS": "bad"}), \
                patch.object(tool.subprocess, "Popen", return_value=child) as popen, \
                patch.object(tool.selectors, "DefaultSelector", return_value=selector), \
                patch.object(tool.os, "read", return_value=b""), \
                patch.object(tool.os, "killpg", side_effect=ProcessLookupError):
            commands.run(["docker", "ps"])
        self.assertEqual(popen.call_args.kwargs["env"], tool.CHILD_ENV)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])

    def test_group_is_killed_and_reaped_before_tracking_cleared(self):
        commands = tool.Commands()
        child = Mock(pid=9999999, stdin=None)
        commands.child = child
        with patch.object(tool.os, "killpg", side_effect=[None, ProcessLookupError]) as kill:
            commands.reap()
        self.assertEqual(kill.call_args_list[0].args, (child.pid, signal.SIGKILL))
        child.wait.assert_called_once()
        self.assertIsNone(commands.child)

    def test_local_python_child_deadline_then_group_reap_no_docker(self):
        commands = tool.Commands()
        with self.assertRaisesRegex(tool.Rejected, "command_deadline"):
            commands.run([sys.executable, "-c", "import time; time.sleep(30)"], cap=0.05)
        child = commands.child
        commands.begin_stop()
        commands.reap()
        self.assertIsNotNone(child.returncode)
        self.assertIsNone(commands.child)

    def test_total_deadline_limits_stop_even_if_failure_late(self):
        clock = Mock(return_value=0)
        commands = tool.Commands(clock)
        clock.return_value = 299
        commands.begin_stop()
        self.assertEqual(commands.phase_end, 300)
        self.assertEqual(commands.remaining(20), 1)
        clock.return_value = 301
        with self.assertRaises(tool.Rejected):
            commands.remaining(1)

    def test_stdout_budget_nonzero_and_individual_deadline(self):
        for failure in ("budget", "nonzero", "deadline"):
            commands = tool.Commands()
            child = Mock(pid=9999999, stdin=None)
            child.wait.return_value = 1 if failure == "nonzero" else 0
            child.stdout.fileno.return_value = 1
            selector = Mock()
            selector.__enter__ = Mock(return_value=selector)
            selector.__exit__ = Mock(return_value=False)
            selector.select.return_value = [] if failure == "deadline" else [(None, None)]
            with self.subTest(failure=failure), \
                    patch.object(tool.subprocess, "Popen", return_value=child), \
                    patch.object(tool.selectors, "DefaultSelector", return_value=selector), \
                    patch.object(tool.os, "read", return_value=b"x" * (tool.LIMIT + 1)
                                 if failure == "budget" else b""):
                with self.assertRaises(tool.Rejected):
                    commands.run(["docker", "ps"])
                self.assertIs(commands.child, child)

    def test_harness_and_child_import_suppress_root_bytecode(self):
        with tempfile.TemporaryDirectory(dir="/root") as temporary:
            stage = Path(temporary)
            for name in ("enable-test-vps-locationiq.py", "configure-test-vps-locationiq.py",
                         "test_vps_file_trust.py"):
                write(stage / name, Path(__file__).with_name(name).read_bytes())
            import subprocess
            environment = dict(os.environ)
            environment.pop("PYTHONDONTWRITEBYTECODE", None)
            result = subprocess.run([sys.executable, str(stage / "enable-test-vps-locationiq.py")],
                                    capture_output=True, timeout=5, env=environment)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["outcome"], "rejected")
            self.assertNotIn(KEY.encode(), result.stdout + result.stderr)
            self.assertFalse(list(stage.rglob("*.pyc")))
            self.assertFalse(list(stage.rglob("__pycache__")))

    def test_main_never_prints_exception_or_key_material(self):
        import contextlib
        output = io.StringIO()
        fake = Mock(published=False)
        fake.commands.remaining.return_value = 270
        fake.execute.side_effect = tool.Rejected(KEY)
        with patch.object(tool.sys, "argv", ["helper", *APPROVED.__dict__.values()]), \
                patch.object(tool, "Activation", return_value=fake), \
                contextlib.redirect_stdout(output):
            self.assertEqual(tool.main(), 1)
        self.assertNotIn(KEY, output.getvalue())
        self.assertEqual(json.loads(output.getvalue()),
                         {"outcome": "rejected", "published": False, "stop": "not_attempted"})


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Linux/root isolated fixtures required.")
    unittest.main()
