#!/usr/bin/env python3
"""Linux/root hermetic pending-OFF policy and shell bridge regressions."""
import sys

sys.dont_write_bytecode = True

import copy
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
from unittest.mock import patch

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "pending_off", SCRIPTS / "test-vps-locationiq-pending-off.py")
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
KEY = "MOCK_PENDING_KEY_NOT_REAL"
OLD = "a" * 64
NEW = "b" * 64
IMAGE_ID = "sha256:" + "c" * 64
BASE = ("BACKEND_IMAGE=old@sha256:old\nBACKEND_REVISION=" + "d" * 40 +
        "\nBACKEND_VERSION=1.5.1\nOTHER=unchanged\nGEOCODER_ENABLED=false\nLOCATIONIQ_KEY=" +
        KEY + "\n").encode()


def record(env=None):
    return {"Id": OLD, "Image": "old-platform", "State": {
        "Running": True, "Health": {"Status": "healthy"}, "StartedAt": "old-start"},
        "Config": {"Env": env if env is not None else [
            line for line in BASE.decode().splitlines()
            if not line.startswith(("LOCATIONIQ_KEY=", "GEOCODER_ENABLED="))],
            "Entrypoint": ["java", "-jar", "app.jar"], "Cmd": [],
            "Labels": {"com.docker.compose.project": "meet-production",
                       "com.docker.compose.service": "backend"}}}


def candidate():
    values = BASE.decode().replace("old@sha256:old", tool.IMAGE).replace(
        "d" * 40, tool.REVISION).replace("1.5.1", tool.VERSION).encode()
    backend = record(values.decode().splitlines())
    backend["Id"] = NEW
    backend["Image"] = IMAGE_ID
    backend["State"]["StartedAt"] = "new-start"
    backend["Config"].update(Image=tool.IMAGE, User="10001:10001")
    backend["Config"]["Labels"].update({
        "org.opencontainers.image.source": "https://github.com/NickolayMamonov/meet-backend-v3",
        "org.opencontainers.image.revision": tool.REVISION,
        "org.opencontainers.image.version": tool.VERSION})
    return values, backend


class PolicyTests(unittest.TestCase):
    def predecessor(self, backend=None, data=BASE, **kwargs):
        tool.verify("predecessor", data, [backend or record()], IMAGE_ID, **kwargs)

    def candidate(self, backend=None, data=None, pending=BASE):
        expected, observed = candidate()
        tool.verify("candidate", data if data is not None else expected,
                    [backend or observed], IMAGE_ID, OLD, "old-start", pending,
                    NEW, "new-start")

    def test_missing_blank_and_explicit_flags(self):
        base = record()["Config"]["Env"]
        for flag in ([], ["GEOCODER_ENABLED=true"], ["GEOCODER_ENABLED=false"]):
            for key in ([], ["LOCATIONIQ_KEY="]):
                self.predecessor(record(base + flag + key))

    def test_same_key_requires_explicit_off(self):
        base = record()["Config"]["Env"] + ["LOCATIONIQ_KEY=" + KEY]
        self.predecessor(record(base + ["GEOCODER_ENABLED=false"]))
        for flag in ([], ["GEOCODER_ENABLED=true"]):
            with self.assertRaises(tool.Rejected):
                self.predecessor(record(base + flag))

    def test_different_nonblank_and_whitespace_keys_reject(self):
        for key in ("other-key", " ", "\t", "key with space", "bad$key"):
            for flag in ("true", "false"):
                with self.subTest(key=key, flag=flag), self.assertRaises(tool.Rejected):
                    self.predecessor(record(record()["Config"]["Env"] +
                                            ["LOCATIONIQ_KEY=" + key, "GEOCODER_ENABLED=" + flag]))

    def test_noop_is_safe_only_explicit_off_same_key(self):
        self.predecessor(record(BASE.decode().splitlines()))

    def test_every_unrelated_assignment_stays_strict(self):
        for name in tool.file_environment(BASE).keys() - tool.CONTROLLED:
            for missing in (True, False):
                env = [line for line in record()["Config"]["Env"]
                       if not line.startswith(name + "=")]
                if not missing:
                    env.append(name + "=different")
                with self.subTest(name=name, missing=missing), self.assertRaises(tool.Rejected):
                    self.predecessor(record(env))

    def test_pending_requires_explicit_false_nonblank_key(self):
        for old, new in ((b"false", b"true"), (b"false", b"FALSE"),
                         (KEY.encode(), b""), (KEY.encode(), b" ")):
            with self.assertRaises(tool.Rejected):
                self.predecessor(data=BASE.replace(old, new))
        with self.assertRaises(tool.Rejected):
            self.predecessor(data=BASE.replace(b"GEOCODER_ENABLED=false\n", b""))

    def test_duplicate_and_alternate_channels(self):
        for line in ("LOCATIONIQ_KEY=x", "OTHER=duplicate",
                     "app_geocoder_enabled=false", "APP_GEOCODER_ENABLED=false",
                     "_JAVA_OPTIONS=-Dapp.geocoder.enabled=false",
                     "SPRING_CONFIG_IMPORT=file:/other", "SPRING_APPLICATION_JSON={}"):
            with self.subTest(line=line):
                with self.assertRaises(tool.Rejected):
                    self.predecessor(data=BASE + (line + "\n").encode())
                with self.assertRaises(tool.Rejected):
                    self.predecessor(record(record()["Config"]["Env"] + [line]))

    def test_invalid_runtime_flag(self):
        for flag in ("", "FALSE", " false", "0"):
            with self.assertRaises(tool.Rejected):
                self.predecessor(record(record()["Config"]["Env"] + ["GEOCODER_ENABLED=" + flag]))

    def test_file_encoding_format_and_budget(self):
        for data in (BASE[:-1], BASE + b"X=\xff\n", BASE + b"X=\0\n",
                     BASE + b"X=$HOME\n", BASE + b"export X=a\n",
                     BASE + b"X=\rbroken\n", BASE + b"x" * tool.LIMIT):
            with self.subTest(size=len(data)), self.assertRaises((tool.Rejected, ValueError)):
                self.predecessor(data=data)

    def test_previous_identity_and_start_are_bound(self):
        self.predecessor(previous_id=OLD, previous_started="old-start")
        for identifier, started in ((NEW, "old-start"), (OLD, "changed")):
            with self.assertRaises(tool.Rejected):
                self.predecessor(previous_id=identifier, previous_started=started)

    def test_runtime_health_command_project_and_count(self):
        for mutate in (
                lambda r: r["State"].update(Running=False),
                lambda r: r["State"].update(Health={"Status": "unhealthy"}),
                lambda r: r["Config"].update(Cmd=["--override"]),
                lambda r: r["Config"]["Labels"].update({"com.docker.compose.project": "other"}),
                lambda r: r.update(Id="bad")):
            backend = record()
            mutate(backend)
            with self.assertRaises(tool.Rejected):
                self.predecessor(backend)
        for records in ([], [record(), record()]):
            with self.assertRaises(tool.Rejected):
                tool.verify("predecessor", BASE, records, IMAGE_ID)

    def test_stopped_predecessor_comparator_does_not_claim_health(self):
        backend = record()
        backend["State"].update(
            Running=False, Status="exited", ExitCode=143, Paused=False,
            Restarting=False, Dead=False, FinishedAt="2026-10-26T17:30:24.669192243Z")
        observed = tool.stopped_predecessor_record(
            [backend], backend["Id"], "2026-10-26T17:30:24.669192243Z"
        )
        tool.compare_predecessor_environment(BASE, observed)
        for expected_id, finished in (
            ("wrong", "2026-10-26T17:30:24.669192243Z"),
            (backend["Id"], "2026-10-26T17:30:24.669192244Z"),
        ):
            with self.assertRaises(tool.Rejected):
                tool.stopped_predecessor_record([backend], expected_id, finished)
        with self.assertRaises(tool.Rejected):
            tool.one_record([backend])
        drifted = json.loads(json.dumps(backend))
        drifted["Config"]["Env"].append("OTHER=changed")
        with self.assertRaises(tool.Rejected):
            tool.compare_predecessor_environment(
                BASE,
                tool.stopped_predecessor_record(
                    [drifted], drifted["Id"],
                    "2026-10-26T17:30:24.669192243Z",
                ),
            )
        with self.assertRaises(tool.Rejected):
            tool.stopped_predecessor_record(
                [backend, backend], backend["Id"],
                "2026-10-26T17:30:24.669192243Z",
            )
        running = json.loads(json.dumps(backend))
        running["State"]["Running"] = True
        with self.assertRaises(tool.Rejected):
            tool.stopped_predecessor_record(
                [running], running["Id"],
                "2026-10-26T17:30:24.669192243Z",
            )

    def test_fixed_public_tuple_not_caller_arbitrary_authorization(self):
        args = [tool.IMAGE, tool.REVISION, tool.VERSION, IMAGE_ID]
        tool.approved(*args)
        for i in range(4):
            changed = list(args)
            changed[i] = "other"
            with self.assertRaises(tool.Rejected):
                tool.approved(*changed)

    def test_candidate_exact_new_image_explicit_off_same_key(self):
        self.candidate()

    def test_candidate_rejects_identity_image_and_labels(self):
        for mutate in (
                lambda r: r.update(Id=OLD), lambda r: r.update(Image="wrong"),
                lambda r: r["Config"].update(Image="wrong"),
                lambda r: r["Config"].update(User="root"),
                lambda r: r["Config"]["Labels"].update({"org.opencontainers.image.revision": "wrong"}),
                lambda r: r["State"].update(Health={"Status": "unhealthy"})):
            _, backend = candidate()
            mutate(backend)
            with self.assertRaises(tool.Rejected):
                self.candidate(backend)

    def test_candidate_rejects_wrong_key_on_missing_and_aliases(self):
        for name, replacement in (("LOCATIONIQ_KEY", "other"), ("GEOCODER_ENABLED", "true"),
                                  ("GEOCODER_ENABLED", None), ("OTHER", "different")):
            _, backend = candidate()
            backend["Config"]["Env"] = [line for line in backend["Config"]["Env"]
                                       if not line.startswith(name + "=")]
            if replacement is not None:
                backend["Config"]["Env"].append(name + "=" + replacement)
            with self.assertRaises(tool.Rejected):
                self.candidate(backend)
        _, backend = candidate()
        backend["Config"]["Env"].append("APP_GEOCODER_ENABLED=false")
        with self.assertRaises(tool.Rejected):
            self.candidate(backend)

    def test_candidate_file_changes_outside_release_tuple_reject(self):
        data, _ = candidate()
        for changed in (data + b"# raced\n", data.replace(b"OTHER=unchanged", b"OTHER=changed"),
                        data.replace(KEY.encode(), b"wrong")):
            with self.assertRaises(tool.Rejected):
                self.candidate(data=changed)
        with self.assertRaises(tool.Rejected):
            self.candidate(pending=BASE + b"# changed snapshot\n")


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.env = self.root / ".env.production"
        self.env.write_bytes(BASE)
        self.env.chmod(0o600)

    def tearDown(self):
        self.assertFalse(list(self.root.rglob("*.pyc")))
        self.tmp.cleanup()

    def args(self):
        return [sys.executable, "-B", str(SCRIPTS / "test-vps-locationiq-pending-off.py"),
                "--phase", "predecessor", "--env-file", str(self.env), "--image", tool.IMAGE,
                "--revision", tool.REVISION, "--version", tool.VERSION, "--image-id", IMAGE_ID]

    def run_cli(self, raw, args=None):
        result = subprocess.run(args or self.args(), input=raw, capture_output=True, timeout=5)
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)
        self.assertNotIn(b"old@sha256", result.stdout + result.stderr)
        return result

    def test_real_cli_safe_success(self):
        result = self.run_cli(json.dumps([record()]).encode())
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"pendingLocationiqOff": True, "verified": True})

    def test_real_cli_invalid_json_duplicate_keys_and_budget_redacted(self):
        for raw in (b"\xff", b"{", b'{"duplicate":1,"duplicate":2}',
                    KEY.encode() * 100000, b"[]"):
            result = self.run_cli(raw)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, b"")
            self.assertEqual(json.loads(result.stdout)["verified"], False)

    def test_real_cli_private_trust_and_path_swap_rejections(self):
        self.env.chmod(0o644)
        self.assertEqual(self.run_cli(json.dumps([record()]).encode()).returncode, 1)
        self.env.chmod(0o600)
        original = self.env
        self.env = self.root / "linked"
        self.env.symlink_to(original)
        self.assertEqual(self.run_cli(json.dumps([record()]).encode()).returncode, 1)

    def test_actual_shell_predecessor_bridge_and_strict_default(self):
        script = """
set -euo pipefail
source "$1/test-vps-runtime-invariants.sh"
runtime_compose() { echo "$CASE_CONTAINER"; }
docker() {
  case "$*" in
    *'range .Config.Env'*) python3 -c 'import json,os; print("\\n".join(json.loads(os.environ["CASE_RECORD"])[0]["Config"]["Env"]))' ;;
    *) echo "$CASE_RECORD" ;;
  esac
}
verify_environment_matches_container "$2" "$1/production-compose.sh" "${@:3}"
"""
        env = dict(os.environ, CASE_CONTAINER=OLD, CASE_RECORD=json.dumps([record()]),
                   DOCKER_CONTEXT="poison", PENDING_LOCATIONIQ_OFF="true")
        # Supply the staged verifier beside a fixed wrapper without changing source.
        staged = self.root / "scripts"
        staged.mkdir()
        for name in ("test-vps-locationiq-pending-off.py", "configure-test-vps-locationiq.py",
                     "test_vps_file_trust.py", "test-vps-runtime-invariants.sh"):
            (staged / name).write_bytes((SCRIPTS / name).read_bytes())
        command = ["bash", "-c", script, "_", str(staged), str(self.root)]
        result = subprocess.run(command, env=env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)  # Inherited mode never opts in.
        result = subprocess.run(command + ["--pending-locationiq-off", tool.IMAGE, tool.REVISION,
                                          tool.VERSION, IMAGE_ID, OLD, "old-start"],
                                env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)


class ComposeRoutingTests(unittest.TestCase):
    def test_real_wrapper_argv(self):
        """Exercise helper routing without replacing runtime_compose or the wrapper."""
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text()
        functions = []
        for name in ("compose", "compose_up"):
            match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)
            self.assertIsNotNone(match)
            functions.append(match.group())
        calls = re.findall(r"^\s*compose_up (-d.*?backend)", source, re.M | re.S)
        self.assertEqual(len(calls), 3)
        expected = ["-d", "--no-deps", "--no-build", "--pull", "never",
                    "--force-recreate", "--wait", "--wait-timeout", "180", "backend"]
        for call in calls:
            self.assertEqual(call.replace("\\\n", " ").split(), expected)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".env.production").write_text("FIXTURE=literal\n")
            wrapper = root / "production-compose.sh"
            shutil.copyfile(SCRIPTS / wrapper.name, wrapper)
            wrapper.chmod(0o755)
            docker = root / "docker"
            docker.write_text("#!/usr/bin/env python3\nimport json,sys\n"
                              "print(json.dumps(sys.argv[1:]))\n")
            docker.chmod(0o755)
            state = root / "state"
            state.mkdir()
            for active in (False, True):
                if active:
                    for name in ("active-compose.yml", "active-runtime.override.yml"):
                        (state / name).write_text("# argv fixture only\n")
                for operation, command, suffix in (
                    ("forward", "compose_up " + calls[1], ["up"] + expected),
                    ("rollback", "compose_up " + calls[0], ["up"] + expected),
                    ("stop", "compose stop backend", ["stop", "backend"]),
                ):
                    with self.subTest(active=active, operation=operation):
                        script = "\n".join(functions) + """
runtime_helper=$1
compose_script=$2
root=$3
""" + command
                        env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"],
                                   PRODUCTION_STATE_DIR=str(state),
                                   MEE_SMTP_FAKE_REMOTE="false",
                                   RUNTIME_USE_REVIEWED_COMPOSE="false")
                        env.pop("RUNTIME_BASE_COMPOSE", None)
                        result = subprocess.run(
                            ["bash", "-euc", script, "_",
                             str(SCRIPTS / "test-vps-runtime-invariants.sh"),
                             str(wrapper), str(root)],
                            env=env, capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        argv = json.loads(result.stdout)
                        files = ["-f", str(state / "active-compose.yml")] if active else [
                            "-f", str(root / "docker-compose.production.yml")]
                        if active:
                            files += ["-f", str(state / "active-runtime.override.yml")]
                        self.assertEqual(argv, [
                            "compose", "-p", "meet-production", "--project-directory",
                            str(root), "--env-file", ".env.production", *files, *suffix])
                        self.assertEqual(argv.count("up"), operation != "stop")


class IntegrationTests(unittest.TestCase):
    """Real deploy CLI, private files and pure policy; all infrastructure is fake."""
    def run_case(self, failure="", opted=True, extra=()):
        with tempfile.TemporaryDirectory(dir="/root") as tmp:
            root = Path(tmp)
            app, stage, state = root / "app", root / "scripts", root / "state"
            app.mkdir()
            stage.mkdir()
            (root / "image-index.json").write_bytes(
                (SCRIPTS / "fixtures/selected-platform/image-index.json")
                .read_bytes().removesuffix(b"\n"))
            state.mkdir(mode=0o700)
            (app / ".env.production").write_bytes(BASE)
            (app / ".env.production").chmod(0o600)
            (app / "docker-compose.production.yml").write_text("services: {}\n")
            compose = root / "target-compose.yml"
            compose.write_text("services: {}\n")
            for name in ("deploy-test-vps-provider-release.sh",
                         "test-vps-locationiq-pending-off.py", "configure-test-vps-locationiq.py",
                         "test_vps_file_trust.py", "production-config-digest.sh",
                         "update-production-release.sh"):
                shutil.copyfile(SCRIPTS / name, stage / name)
                (stage / name).chmod(0o755)
            deploy_copy = stage / "deploy-test-vps-provider-release.sh"
            deploy_copy.write_text(deploy_copy.read_text().replace(
                "/var/lib/meet-production", str(root / "active")))
            if failure == "env-update":
                (stage / "update-production-release.sh").write_text("#!/bin/bash\nexit 1\n")
            # Existing executable contract, with hardening infrastructure stubbed.
            (stage / "test-vps-runtime-invariants.sh").write_text(
                'source "' + str(SCRIPTS / "test-vps-runtime-invariants.sh") + '"\n' + """
runtime_compose() { python3 "$CASE_FAKE" compose "${@:3}"; }
runtime_image_id() { echo "$CASE_OLD_IMAGE_ID"; }
verify_runtime_invariants() {
  if [ "${7:-}" = --target-image-proof ]; then
    verify_environment_matches_container "$1" "$2" "${@:9}"
  else
    verify_environment_matches_container "$1" "$2" "${@:7}"
  fi
}
""")
            (stage / "production-compose.sh").write_text("#!/bin/bash\nexit 99\n")
            (stage / "production-compose.sh").chmod(0o755)
            fake = root / "fake.py"
            defaults = {"CASE_ROOT": str(root), "CASE_FAILURE": failure, "CASE_KEY": KEY,
                        "CASE_OLD": OLD, "CASE_NEW": NEW, "CASE_IMAGE_ID": IMAGE_ID,
                        "CASE_OLD_IMAGE_ID": "sha256:" + "e" * 64,
                        "CASE_IMAGE": tool.IMAGE, "CASE_REVISION": tool.REVISION}
            fake.write_text("import os\nfor k,v in " + repr(defaults) +
                            ".items(): os.environ.setdefault(k,v)\n" + FAKE_INFRASTRUCTURE)
            (stage / "test-vps-provider-credential.py").write_text(
                "import runpy,os,sys\nsys.argv.insert(1,'provider')\n"
                "runpy.run_path(os.environ['CASE_FAKE'],run_name='__main__')\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for name, body in {
                "docker": 'exec python3 "' + str(fake) + '" docker "$@"',
                "curl": 'exec python3 "' + str(fake) + '" curl "$@"',
            }.items():
                (bin_dir / name).write_text("#!/bin/bash\n" + body + "\n")
                (bin_dir / name).chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                       CASE_FAKE=str(fake), CASE_ROOT=str(root), CASE_FAILURE=failure,
                       CASE_OLD_IMAGE_ID="sha256:" + "e" * 64,
                       CASE_IMAGE_ID=IMAGE_ID, CASE_IMAGE=tool.IMAGE, CASE_REVISION=tool.REVISION,
                       CASE_KEY=KEY, CASE_OLD=OLD, CASE_NEW=NEW,
                       TEST_VPS_STATE_ROOT=str(state), PRODUCTION_STATE_DIR=str(root / "active"),
                       # An inherited mode must never activate the opt-in.
                       APPLY_PENDING_LOCATIONIQ_OFF="true")
            (root / "active").mkdir()
            args = ["bash", str(stage / "deploy-test-vps-provider-release.sh"),
                    "--root", str(app), "--base-compose", str(compose), "--image", tool.IMAGE,
                    "--revision", tool.REVISION, "--version", tool.VERSION, "--run-key", "123-1",
                    "--mode", "deploy", "--failure-policy", "manual-stop",
                    "--public-url", "https://fixture.invalid"]
            if opted:
                args.append("--pending-locationiq-off")
            args.extend(extra)
            result = subprocess.run(args, env=env, capture_output=True, timeout=30)
            output = result.stdout + result.stderr
            self.assertNotIn(KEY.encode(), output)
            self.assertNotIn(b"OTHER=unchanged", output)
            self.assertNotIn(__import__("hashlib").sha256(KEY.encode()).hexdigest().encode(), output)
            trace = (root / "trace").read_text() if (root / "trace").exists() else ""
            if (state / ".provider-transaction.current").exists():
                trace += "recovery-marker-retained\n"
            self.assertNotIn("rollback", trace)
            self.assertLessEqual(trace.count("up-new"), 1)
            self.assertNotIn("up-old", trace)
            self.assertFalse(list(root.rglob("*.pyc")))
            return result, trace, (app / ".env.production").read_bytes()

    def test_real_cli_pending_transition_one_new_recreate(self):
        result, trace, after = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr.decode() + trace)
        self.assertEqual(trace.count("up-new"), 1)
        self.assertNotIn("stop", trace)
        self.assertIn(b"GEOCODER_ENABLED=false\n", after)
        self.assertIn(KEY.encode(), after)
        self.assertIn(b"outcome\":\"committed", result.stdout)

    def test_real_cli_strict_default_rejects_pending_without_activation(self):
        result, trace, after = self.run_case(opted=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("up-new", trace)
        self.assertNotIn("stop", trace)
        self.assertEqual(after, BASE)

    def test_real_cli_rejects_incompatible_optin_arguments_before_writers(self):
        for extra in (("--mode", "rollback-drill"),
                      ("--failure-policy", "automatic-rollback"),
                      ("--closed-beta-safety",),
                      ("--pending-locationiq-off",),
                      ("--image", "wrong"),
                      ("--revision", "wrong"),
                      ("--version", "1.7.0")):
            with self.subTest(extra=extra):
                result, trace, after = self.run_case(extra=extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("up-new", trace)
                self.assertNotIn("stop", trace)
                self.assertEqual(after, BASE)

    def test_real_cli_prewrite_failures_preserve_predecessor_and_pending(self):
        for failure in ("target-image", "snapshot-race", "prepare", "prewriter-restart"):
            with self.subTest(failure=failure):
                result, trace, after = self.run_case(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("up-new", trace)
                self.assertNotIn("stop", trace)
                if failure != "snapshot-race":
                    self.assertEqual(after, BASE)

    def test_cleanup_rejects_changed_pending_key_and_retains_recovery_marker(self):
        for failure in ("prepared-key-race", "cleanup-key-race"):
            with self.subTest(failure=failure):
                result, trace, after = self.run_case(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("up-new", trace)
                self.assertNotIn("stop", trace)
                self.assertNotIn("finish", trace)
                self.assertIn("recovery-marker-retained", trace)
                self.assertIn(b"RECOVERY_REQUIRED", result.stderr)
                self.assertNotEqual(after, BASE)

    def test_real_cli_postwrite_failures_manual_stop_never_rollback(self):
        for failure in ("env-update", "recreate", "candidate-key", "candidate-on", "candidate-alias",
                        "candidate-id", "candidate-image", "candidate-health",
                        "unrelated", "final-restart", "finish", "stop",
                        "signal-term", "signal-int", "signal-hup", "timeout"):
            with self.subTest(failure=failure):
                result, trace, after = self.run_case(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("stop", trace)
                self.assertIn(b"GEOCODER_ENABLED=false\n", after)
                self.assertIn(KEY.encode(), after)


FAKE_INFRASTRUCTURE = r'''
import json, os, pathlib, sys
r = pathlib.Path(os.environ["CASE_ROOT"])
failure = os.environ["CASE_FAILURE"]
kind, *args = sys.argv[1:]
new = (r / "new").exists()
key = os.environ["CASE_KEY"]
oldid, newid = os.environ["CASE_OLD"], os.environ["CASE_NEW"]
def trace(value):
    with (r / "trace").open("a") as f: f.write(value + "\n")
def die(): raise SystemExit(1)
trace("call " + kind + " " + " ".join(args))
def record():
    data = (r / "app/.env.production").read_text().splitlines()
    if not new:
        data = [x for x in data if not x.startswith(("GEOCODER_ENABLED=", "LOCATIONIQ_KEY="))]
    if new and failure == "candidate-key":
        data = [x if not x.startswith("LOCATIONIQ_KEY=") else "LOCATIONIQ_KEY=wrong" for x in data]
    if new and failure == "candidate-on":
        data = [x if not x.startswith("GEOCODER_ENABLED=") else "GEOCODER_ENABLED=true" for x in data]
    if new and failure == "candidate-alias": data.append("APP_GEOCODER_ENABLED=false")
    if new and failure == "unrelated":
        data = [x if not x.startswith("OTHER=") else "OTHER=wrong" for x in data]
    count = int((r / "record-count").read_text()) if (r / "record-count").exists() else 0
    (r / "record-count").write_text(str(count + 1))
    started = "new-start" if new else "old-start"
    if not new and failure == "prewriter-restart" and (r / "prepared").exists(): started = "raced"
    rec = {"Id": newid if new else oldid,
      "Image": os.environ["CASE_IMAGE_ID"] if new else os.environ["CASE_OLD_IMAGE_ID"],
      "State":{"Running":True,"Health":{"Status":"healthy"},"StartedAt":started},
      "Config":{"Env":data,"Entrypoint":["java","-jar","app.jar"],"Cmd":[],
        "Image":os.environ["CASE_IMAGE"] if new else "old@sha256:old","User":"10001:10001",
        "Labels":{"com.docker.compose.project":"meet-production","com.docker.compose.service":"backend",
          "com.docker.compose.config-hash":"f"*64,
          "org.opencontainers.image.source":"https://github.com/NickolayMamonov/meet-backend-v3",
          "org.opencontainers.image.revision":os.environ["CASE_REVISION"],
          "org.opencontainers.image.version":"1.6.0"}}}
    if new and failure == "candidate-id": rec["Id"] = oldid
    if new and failure == "candidate-image": rec["Image"] = "wrong"
    if new and failure == "candidate-health": rec["State"]["Health"]["Status"] = "unhealthy"
    if new and failure == "final-restart" and (r / "public-complete").exists():
        rec["Id"] = "9"*64
    return rec
if kind == "provider":
    cmd = args[0]
    if cmd in ("check","retention-check","check-image"): pass
    elif cmd == "verify":
        if failure == "cleanup-key-race" and not (r / "prewriter-failed").exists():
            (r / "prewriter-failed").touch()
            die()
    elif cmd == "state-publish":
        state = pathlib.Path(args[args.index("--state-root")+1])
        owned = state / "123-1-final-deploy"
        owned.mkdir(mode=0o700)
        request = json.load(sys.stdin)
        (owned / "target-image-proof.json").write_text(
            json.dumps(request["targetImageProof"], separators=(",", ":")))
    elif cmd == "observe":
        print(json.dumps({"schemaVersion":1,"providerEnabled":False,"credentialMountPresent":False,
                          "credentialMountReadOnly":False,"outcome":"observed"}))
        if failure == "snapshot-race":
            with (r / "app/.env.production").open("a") as f: f.write("# raced\n")
    elif cmd == "prepare":
        marker = r / "state/.provider-transaction.current"
        marker_data = json.loads(marker.read_text())
        marker_data.update(phase="preparing", providerEnabled=False, durableDisposition="none")
        marker.write_text(json.dumps(marker_data))
        marker.chmod(0o600)
        (r / "prepared").touch()
        if failure == "prepared-key-race":
            path = r / "app/.env.production"
            path.write_text(path.read_text().replace(
                os.environ["CASE_KEY"], "MOCK_RACED_PENDING_NOT_REAL"))
        if failure == "prepare": die()
    elif cmd == "finish":
        if failure == "finish": die()
        trace("finish")
elif kind == "compose":
    if args[:3] == ["ps","-q","backend"]:
        print(newid if new else oldid)
    elif args and args[0] == "stop":
        trace("stop")
        if failure == "stop": die()
    elif args == ["up", "-d", "--no-deps", "--no-build", "--pull", "never",
                  "--force-recreate", "--wait", "--wait-timeout", "180", "backend"]:
        trace("up-new")
        (r / "new").touch()
        if failure.startswith("signal-"):
            import signal
            os.kill(os.getppid(), getattr(signal, "SIG" + failure.split("-")[1].upper()))
            die()
        if failure == "timeout": sys.exit(124)
        if failure in ("recreate", "stop"): die()
    else: die()
elif kind == "docker":
    if args[:2] == ["image","inspect"]:
        if failure == "target-image": die()
        ref = args[2]
        fmt = args[args.index("--format")+1] if "--format" in args else ""
        if ".Id" in fmt: print(os.environ["CASE_OLD_IMAGE_ID"] if ref.startswith("old") else os.environ["CASE_IMAGE_ID"])
        elif "image.revision" in fmt: print(os.environ["CASE_REVISION"])
        elif "image.version" in fmt: print("1.6.0")
        elif "image.source" in fmt: print("https://github.com/NickolayMamonov/meet-backend-v3")
        elif ".Config.User" in fmt: print("10001:10001")
        else: print(json.dumps([{
            "Id": os.environ["CASE_IMAGE_ID"],
            "Os": "linux", "Architecture": "amd64",
            "RepoDigests": [os.environ["CASE_IMAGE"]],
            "Config": {"Env": [], "User": "10001:10001", "Labels": {
                "org.opencontainers.image.source": "https://github.com/NickolayMamonov/meet-backend-v3",
                "org.opencontainers.image.revision": os.environ["CASE_REVISION"],
                "org.opencontainers.image.version": "1.6.0"}}}]))
    elif args and args[0] == "inspect":
        rec = record()
        fmt = args[args.index("--format")+1] if "--format" in args else ""
        if "config-hash" in fmt: print("f"*64)
        elif "StartedAt" in fmt: print(rec["State"]["StartedAt"])
        elif "range .Config.Env" in fmt: print("\n".join(rec["Config"]["Env"]))
        else: print(json.dumps([rec]))
    elif args[:1] == ["compose"]:
        rec = record()
        print(json.dumps({"services":{"backend":{"environment":dict(x.split("=",1) for x in rec["Config"]["Env"])}}}))
    else: die()
elif kind == "curl":
    if failure == "cleanup-key-race" and (r / "prewriter-failed").exists():
        path = r / "app/.env.production"
        path.write_text(path.read_text().replace(
            os.environ["CASE_KEY"], "MOCK_RACED_PENDING_NOT_REAL"))
    url = next(x for x in args if x.startswith(("https://", "http://")))
    if "/admin/" in url:
        print("403",end="")
        if "X-Admin-Key: wrong" in args: (r / "public-complete").touch()
    elif url.startswith("http://"): print("Location: https://fixture.invalid/meetings\r\n302",end="")
    elif url.endswith("/actuator"): print("404",end="")
    else: print("[]\n200",end="")
else: die()
'''


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Requires Linux root; hermetic fixtures only.")
    unittest.main()
