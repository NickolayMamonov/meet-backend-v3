#!/usr/bin/env python3
"""Root/Linux, offline exact-recovery contracts. All credentials are fictional."""
import sys

sys.dont_write_bytecode = True

import base64
import contextlib
import copy
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import struct
import subprocess
import tempfile
import unittest
import resource
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "provider_credential", SCRIPTS / "test-vps-provider-credential.py")
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)
OLD = "6d4a332640760361207d36297752b0265eae6a445396ea5a5b6f8c51a47f1f7b"
OLD_IMAGE = "sha256:8e405258c34d70d6b42d226458c381f55df47d37fa743b754e1066e05f3ae1a0"
NEW = "c" * 64
NEW_IMAGE = "sha256:" + "d" * 64
REVISION = "e" * 40
SUCCESSOR = "99999999999-1"
KEY = "FICTIONAL_LOCATIONIQ_KEY_ONLY"
IMAGE = "ghcr.io/nickolaymamonov/meet-backend-v3@" + helper.FORWARD_TARGET["indexDigest"]
SOURCE = "https://github.com/NickolayMamonov/meet-backend-v3"


def encode(value):
    return json.dumps(value, separators=(",", ":")).encode()


class Fixture:
    def __init__(self, disposition="none"):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.app = self.root / "app"
        self.active = self.root / "active"
        self.states = self.root / "states"
        self.archive_parent = self.root / "archive"
        self.credentials = self.root / "credentials"
        for path in (self.app, self.active, self.states,
                     self.archive_parent, self.credentials):
            path.mkdir(mode=0o700)
        self.archive = self.archive_parent / "40368479855-1-forward-reconciled"
        self.origin = self.states / helper.FORWARD_ORIGIN_STATE
        self.origin.mkdir(mode=0o700)
        self.successor = self.states / (SUCCESSOR + "-final-deploy")
        self.pointer = self.states / ".provider-transaction.current"
        self.patches = [
            mock.patch.object(helper, "FORWARD_ROOT", str(self.app)),
            mock.patch.object(helper, "FORWARD_ACTIVE_ROOT", str(self.active)),
            mock.patch.object(helper, "FORWARD_ARCHIVE", str(self.archive)),
            mock.patch.object(helper, "HOST_CREDENTIAL_PARENT", str(self.credentials)),
            mock.patch.object(helper, "HOST_CREDENTIAL_PATH",
                              str(self.credentials / "firebase-service-account.json")),
        ]
        for patch in self.patches:
            patch.start()
        self.paths = helper._forward_external_paths(SUCCESSOR)
        self.disposition = disposition
        self.enabled = disposition != "none"
        flags = ("APP_PUSH_PROVIDER_ENABLED=" + str(self.enabled).lower() + "\n"
                 "APP_PUSH_DISCOVERY_ENABLED=false\nAPP_PUSH_DISPATCH_ENABLED=false\n"
                 "APP_PUSH_DIAGNOSTIC_ENABLED=false\nAPP_PUSH_MAINTENANCE_ENABLED=false\n"
                 "APP_PUSH_PROJECT_ID=meeting-1d258\nAPP_PUSH_CREDENTIALS_FILE=" +
                 (helper.CONTAINER_CREDENTIAL_PATH if self.enabled else "") + "\n")
        self.old_ref = "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "f" * 64
        self.pending = (
            f"BACKEND_IMAGE={self.old_ref}\nBACKEND_REVISION={REVISION}\n"
            "BACKEND_VERSION=1.5.2\nOTHER=unchanged\nGEOCODER_ENABLED=false\n"
            f"LOCATIONIQ_KEY={KEY}\n" + flags).encode()
        self.target_env = self.pending.replace(self.old_ref.encode(), IMAGE.encode()).replace(
            REVISION.encode(), helper.FORWARD_TARGET["source"].encode()).replace(
            b"BACKEND_VERSION=1.5.2\n", b"BACKEND_VERSION=1.6.0\n")
        self.write(self.paths["production-env"], self.pending)
        pending_identity = self.saved_identity(self.paths["production-env"])
        replacement = self.app / "target-env"
        self.write(replacement, self.target_env)
        os.replace(replacement, self.paths["production-env"])
        self.write(self.paths["original-base"], b"services: {}\n")
        self.write(self.paths["reviewed-base"], b"services: {}\n")
        self.fallback = self.app / "docker-compose.production.yml"
        self.write(self.fallback, b"# unrelated root fallback: no historical witness\n")
        self.write(self.paths["active-compose"], b"services: {}\n")
        self.write(self.paths["active-runtime"], b"services: {backend: {}}\n")
        self.write(self.states / ".deploy.lock", b"")
        self.lock_fd = os.open(self.states / ".deploy.lock", os.O_RDWR)
        self.saved_nine = None
        try:
            self.saved_nine = os.dup(9)
        except OSError:
            pass
        os.dup2(self.lock_fd, 9)
        helper.fcntl.flock(9, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)
        self.backend = self.backend_record()
        marker = {
            "schemaVersion": 1, "runKey": helper.FORWARD_ORIGIN_KEY,
            "phase": "preparing" if self.enabled else "applying",
            "providerEnabled": self.enabled, "durableDisposition": "none",
        }
        self.write(self.pointer, encode(marker))
        if self.enabled:
            credential = encode({
                "type": "service_account", "project_id": helper.EXPECTED_PROJECT,
                "client_email": "fictional@example.invalid", "client_id": "fictional",
                "private_key_id": "fictional",
                "private_key": "-----BEGIN PRIVATE KEY-----\nfictional\n-----END PRIVATE KEY-----",
                "token_uri": "https://example.invalid/token",
            })
            source = (Path(helper.HOST_CREDENTIAL_PATH) if disposition == "reused"
                      else self.root / "original-credential.json")
            self.write(source, credential, 0o440)
            os.chown(source, 0, 10001)
            self.backend["Mounts"].append({
                "Type": "bind", "Source": str(source),
                "Destination": helper.CONTAINER_CREDENTIAL_PATH, "RW": False,
            })
            with contextlib.redirect_stdout(io.StringIO()):
                helper._prepare(helper.FORWARD_ORIGIN_KEY, str(self.states),
                                "", encode([self.backend]))
            marker = helper._marker(str(self.states), helper.FORWARD_ORIGIN_KEY)
            assert marker["durableDisposition"] == disposition
            marker["phase"] = "applying"
            self.pointer.write_bytes(encode(marker))
        files = {
            helper.OWNER_MARKER: helper._state_marker(helper.FORWARD_ORIGIN_KEY, "final-deploy"),
            "config.env.production": self.pending,
            "config.env.production.identity": pending_identity,
            "config.env.target": self.target_env,
            "config.env.target.identity": self.saved_identity(self.paths["production-env"]),
            "config.env.previous": self.pending,
            "config.base-compose.yml": b"services: {}\n",
            "config.base-compose.yml.identity": self.saved_identity(self.paths["original-base"]),
            "candidate-active-compose.yml": b"services: {}\n",
            "candidate-active-compose.identity": self.saved_identity(self.paths["active-compose"]),
            "candidate-active-runtime.yml": b"services: {backend: {}}\n",
            "candidate-active-runtime.identity": self.saved_identity(self.paths["active-runtime"]),
            "target-runtime.override.yml": b"services: {backend: {}}\n",
            "previous-image": (self.old_ref + "\n").encode(),
            "previous-image-id": (OLD_IMAGE + "\n").encode(),
            "previous-revision": (REVISION + "\n").encode(),
            "previous-version": b"1.5.2\n",
            "previous-runtime-config-hash": ("1" * 64 + "\n").encode(),
        }
        for name, data in files.items():
            self.write(self.origin / name, data)
        self.original_files = files
        self.old_image = self.image_record(OLD_IMAGE, REVISION, "1.5.2")
        self.target = self.image_record(NEW_IMAGE, helper.FORWARD_TARGET["source"], "1.6.0")
        self.rendered = self.rendered_record()
        self.candidate = copy.deepcopy(self.backend)
        self.candidate["Id"] = NEW
        self.candidate["Image"] = NEW_IMAGE
        self.candidate["Config"].update(
            Image=IMAGE, Env=self.target_env.decode().splitlines())
        self.candidate["Config"]["Labels"].update({
            "org.opencontainers.image.revision": helper.FORWARD_TARGET["source"],
            "org.opencontainers.image.version": "1.6.0",
            "com.docker.compose.config-hash": "2" * 64,
        })
        self.candidate["State"].update(
            Running=True, Status="running", ExitCode=0,
            Health={"Status": "healthy"}, StartedAt="2026-10-27T01:00:00Z", FinishedAt="")
        if self.enabled:
            self.candidate["Mounts"][-1]["Source"] = helper.HOST_CREDENTIAL_PATH

    @staticmethod
    def write(path, data, mode=0o600):
        path = Path(path)
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    @staticmethod
    def saved_identity(path):
        info = os.stat(path)
        fields = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
                  info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        return (":".join(map(str, fields)) + ":" +
                hashlib.sha256(Path(path).read_bytes()).hexdigest() + "\n").encode()

    def historical_original(self):
        path = Path(self.paths["original-base"])
        path.chmod(0o644)
        os.chown(path, 1001, 1001)
        name = "config.base-compose.yml.identity"
        data = self.saved_identity(path)
        self.write(self.origin / name, data)
        self.original_files[name] = data

    def backend_record(self):
        return {
            "Id": OLD, "Image": OLD_IMAGE,
            "Config": {
                "Image": self.old_ref,
                "Env": [line for line in self.pending.decode().splitlines()
                        if not line.startswith(("LOCATIONIQ_KEY=", "GEOCODER_ENABLED="))],
                "Entrypoint": ["java", "-jar", "app.jar"], "Cmd": [], "User": "10001:10001",
                "Labels": {
                    "com.docker.compose.project": "meet-production",
                    "com.docker.compose.service": "backend",
                    "com.docker.compose.config-hash": "1" * 64,
                    "org.opencontainers.image.source": SOURCE,
                    "org.opencontainers.image.revision": REVISION,
                    "org.opencontainers.image.version": "1.5.2",
                },
                "Healthcheck": {"Test": ["CMD", "curl", "--fail", "--silent", "--show-error",
                                         "http://127.0.0.1:8080/meetings"]},
            },
            "State": {
                "Running": False, "Status": "exited", "ExitCode": 143,
                "StartedAt": "2026-10-26T16:00:00Z", "FinishedAt": helper.FORWARD_FINISHED,
                "Paused": False, "Restarting": False, "Dead": False,
            },
            "HostConfig": {
                "ReadonlyRootfs": True, "RestartPolicy": {"Name": "unless-stopped"},
                "LogConfig": {"Type": "local"}, "CapDrop": ["ALL"],
                "SecurityOpt": ["no-new-privileges:true"], "Tmpfs": {"/tmp": ""},
                "Memory": 805306368,
                "Init": True, "NetworkMode": "meet-production_default",
                "PortBindings": {"8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]},
            },
            "Mounts": [{"Type": "volume", "Name": "meet-production_uploads_data",
                        "Source": "/var/lib/docker/volumes/uploads/_data",
                        "Destination": "/data/uploads", "RW": True}],
            "NetworkSettings": {"Networks": {"meet-production_default": {}}},
        }

    @staticmethod
    def image_record(identifier, revision, version):
        return {"Id": identifier, "Architecture": "amd64", "Os": "linux",
                "Config": {"Env": [], "User": "10001:10001",
                           "Entrypoint": ["java", "-jar", "app.jar"], "Cmd": [],
                           "Labels": {"org.opencontainers.image.source": SOURCE,
                                      "org.opencontainers.image.revision": revision,
                                      "org.opencontainers.image.version": version}}}

    def rendered_record(self):
        return {"services": {
            "backend": {
                "image": IMAGE, "pull_policy": "never", "user": "10001:10001",
                "read_only": True, "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"], "restart": "unless-stopped",
                "logging": {"driver": "local"}, "mem_limit": 805306368,
                "environment": dict(line.split("=", 1)
                                    for line in self.target_env.decode().splitlines()),
                "ports": [{"host_ip": "127.0.0.1", "target": 8080, "published": "8080"}],
                "volumes": [{"type": "volume", "source": "uploads_data",
                             "target": "/data/uploads"}] + ([{
                                 "type": "bind", "source": helper.HOST_CREDENTIAL_PATH,
                                 "target": helper.CONTAINER_CREDENTIAL_PATH, "read_only": True,
                                 "bind": {"create_host_path": False}}] if self.enabled else []),
                "healthcheck": {"test": self.backend["Config"]["Healthcheck"]["Test"]},
            },
            "postgres": {},
        }, "volumes": {"postgres_data": {"name": "meet-production_postgres_data"},
                       "uploads_data": {"name": "meet-production_uploads_data"}}}

    def bundle(self):
        return encode({"backend": [self.backend], "previousImage": [self.old_image],
                       "targetImage": [self.target], "platformImage": [self.target],
                       "rendered": self.rendered})

    def admit(self):
        with contextlib.redirect_stdout(io.StringIO()):
            helper._forward_admission(str(self.states), SUCCESSOR, str(self.app),
                                      self.paths["reviewed-base"], self.bundle())

    def phase(self):
        helper._forward_phase(str(self.states), SUCCESSOR, "verifying")

    def complete(self):
        with contextlib.redirect_stdout(io.StringIO()):
            helper._forward_complete(str(self.states), SUCCESSOR, encode([self.candidate]))

    def marker(self):
        return json.loads(self.pointer.read_bytes())

    def close(self):
        helper.fcntl.flock(9, helper.fcntl.LOCK_UN)
        if self.saved_nine is not None:
            os.dup2(self.saved_nine, 9)
            os.close(self.saved_nine)
        else:
            os.close(9)
        if self.lock_fd != 9:
            os.close(self.lock_fd)
        for patch in reversed(self.patches):
            patch.stop()
        self.tmp.cleanup()


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.fixture = None

    def tearDown(self):
        if self.fixture:
            self.fixture.close()

    def fresh(self, disposition="none"):
        if self.fixture:
            self.fixture.close()
        self.fixture = Fixture(disposition)
        return self.fixture

    def unchanged(self, fixture):
        self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
        self.assertFalse(fixture.successor.exists())
        self.assertFalse(fixture.archive.exists())
        self.assertEqual(Path(fixture.paths["production-env"]).read_bytes(), fixture.target_env)


class StagedOwnershipTests(unittest.TestCase):
    def test_runner_tar_is_normalized_before_native_reviewed_base_admission(self):
        workflow = (SCRIPTS.parent / ".github/workflows/deploy-test-vps.yml").read_text()
        extraction = [line.strip() for line in workflow.splitlines()
                      if 'tar ' in line and '"$stage/tooling.tar"' in line]
        self.assertEqual(extraction, ['tar --no-same-owner -xf "$stage/tooling.tar" -C "$stage"'])
        files = ("docker-compose.production.yml",
                 "scripts/deploy-test-vps-provider-release.sh",
                 "scripts/test-vps-provider-credential.py")
        # /tmp is intentionally not a trusted ancestor for the native reader.
        with tempfile.TemporaryDirectory(prefix="staging-owner-", dir="/") as directory:
            root = Path(directory)
            root.chmod(0o755)
            inputs = root / "inputs"
            inputs.mkdir()
            for name in files:
                path = inputs / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes((SCRIPTS.parent / name).read_bytes())
                path.chmod(0o644)
            runner = root / "runner"
            runner.mkdir()
            os.chown(runner, 1001, 1001)

            def runner_identity():
                os.setgroups([])
                os.setgid(1001)
                os.setuid(1001)

            subprocess.run(["bash", "-c", '''
                set -euo pipefail
                source=$1; stage=$2/stage; archive=$2/tooling.tar
                mkdir -p "$stage/scripts"
                files=(docker-compose.production.yml
                  scripts/deploy-test-vps-provider-release.sh
                  scripts/test-vps-provider-credential.py)
                for file in "${files[@]}"; do cp -- "$source/$file" "$stage/$file"; done
                chmod 755 "$stage"/scripts/*.sh "$stage"/scripts/test-vps-provider-credential.py
                (cd "$stage"; sha256sum "${files[@]}" > SHA256SUMS)
                tar -C "$stage" -cf "$archive" "${files[@]}" SHA256SUMS
                ''', "_", str(inputs), str(runner)], check=True, preexec_fn=runner_identity)
            for normalized in (False, True):
                with self.subTest(normalized=normalized):
                    stage = root / ("normalized" if normalized else "preserved")
                    stage.mkdir(mode=0o700)
                    shutil.copyfile(runner / "tooling.tar", stage / "tooling.tar")
                    command = extraction[0] if normalized else 'tar -xf "$stage/tooling.tar" -C "$stage"'
                    subprocess.run(["bash", "-c",
                                    'set -euo pipefail; stage=$1; ' + command +
                                    '; (cd "$stage"; sha256sum -c SHA256SUMS); chmod 755 "$stage"/scripts/*.sh',
                                    "_", str(stage)], check=True, stdout=subprocess.PIPE)
                    for name in files:
                        info = (stage / name).stat()
                        self.assertEqual((info.st_uid, info.st_gid),
                                         (0, 0) if normalized else (1001, 1001))
                        self.assertEqual(stat.S_IMODE(info.st_mode),
                                         0o644 if name == files[0] else 0o755)
                        self.assertEqual((stage / name).read_bytes(), (inputs / name).read_bytes())
                    if normalized:
                        _, content = helper._forward_read_external(str(stage / files[0]))
                        self.assertEqual(content, (inputs / files[0]).read_bytes())
                    else:
                        with self.assertRaises(helper.ProviderError) as error:
                            helper._forward_read_external(str(stage / files[0]))
                        self.assertEqual(error.exception.category, "RECOVERY_REQUIRED")


class ForwardTests(FixtureTests):
    def test_competing_deployment_lock_blocks_admission_without_publication(self):
        fixture = self.fresh()
        helper.fcntl.flock(9, helper.fcntl.LOCK_UN)
        contender = subprocess.Popen([
            sys.executable, "-B", "-c",
            "import fcntl,sys; f=open(sys.argv[1],'rb'); "
            "fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.read()",
            str(fixture.states / ".deploy.lock")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(contender.stdout.readline(), b"locked\n")
            with self.assertRaises((helper.ProviderError, BlockingIOError)):
                fixture.admit()
            self.unchanged(fixture)
        finally:
            contender.communicate(input=b"", timeout=10)
            self.assertEqual(contender.returncode, 0)
        helper.fcntl.flock(9, helper.fcntl.LOCK_EX | helper.fcntl.LOCK_NB)

    def test_mixed_producer_assets_preserved_through_all_phases_and_retention(self):
        import runpy
        producer = runpy.run_path(str(SCRIPTS / "test-test-vps-state-admission.py"))
        fixture = self.fresh()
        producer["beta"](fixture.states)
        producer["generation"](fixture.states)
        Fixture.write(fixture.states / ".smtp-last-good.current",
                      b"fixture-apply-ABC123\n")
        (fixture.states / ".smtp-transactions").mkdir(mode=0o700)
        legacy = fixture.states / "123-1-final-deploy"
        legacy.mkdir(mode=0o755)
        Fixture.write(legacy / "unowned", b"fictional")
        before = {name: producer["snapshot"](fixture.states / name)
                  for name in ("beta-recovery-fixture-123", ".smtp-last-good-generations",
                               ".smtp-transactions", legacy.name)}
        fixture.admit()
        helper._forward_revalidate(str(fixture.states), SUCCESSOR, encode([fixture.backend]))
        fixture.phase()
        fixture.complete()
        with contextlib.redirect_stdout(io.StringIO()):
            helper._retention_check("", str(fixture.states))
            helper._retention_delete(str(fixture.states), str(fixture.successor))
        for name, saved in before.items():
            self.assertEqual(producer["snapshot"](fixture.states / name), saved)

    def test_new_foreign_entries_at_every_adoption_boundary_block_next_mutation(self):
        for boundary in ("state-staged", "state-published", "pointer-ready"):
            with self.subTest(boundary=boundary):
                fixture = self.fresh()
                sidecar = fixture.states / ".runtime.foreign.body"
                def inject(stage):
                    if stage == boundary:
                        Fixture.write(sidecar, b"unbound")
                with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=inject):
                    with self.assertRaises(helper.ProviderError):
                        fixture.admit()
                self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
                self.assertEqual(sidecar.read_bytes(), b"unbound")
                self.assertFalse(fixture.archive.exists())

    def test_low_rlimit_large_foreign_production_workers(self):
        for limit in (64, 1024):
            result = subprocess.run(
                [sys.executable, "-B", __file__, "--resource-worker", str(limit)],
                capture_output=True, timeout=300)
            self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())
            print(result.stdout.decode(), end="", flush=True)

    def test_resource_failures_preserve_exact_adoption_publications(self):
        module = helper._forward_state_module()
        actual = module.Inventory.recheck
        staging = ".provider-state." + SUCCESSOR + "-final-deploy.tmp"
        temporary = ".provider-transaction." + SUCCESSOR + ".forward"
        for boundary, staged, published, temp in (
                ("before-staging", False, False, False),
                ("state-staged", True, False, False),
                ("state-published", False, True, False),
                ("temporary-written", False, True, True),
                ("pointer-ready", False, True, True)):
            for code in (errno.EMFILE, errno.ENFILE):
                with self.subTest(boundary=boundary, errno=code):
                    fixture = self.fresh()
                    baseline = len(os.listdir("/proc/self/fd"))
                    armed = [boundary == "before-staging"]
                    calls = [0]
                    def hook(stage):
                        if stage == boundary:
                            armed[0] = True
                    def recheck(inv, *args, **kwargs):
                        calls[0] += 1
                        # Constructor's initial recheck must finish first.
                        ready = armed[0] and calls[0] > 1
                        if boundary == "temporary-written":
                            ready = temporary in kwargs.get("added", ())
                        if ready:
                            with mock.patch.object(os, "open",
                                                   side_effect=OSError(code, "fictional exhaustion")):
                                return actual(inv, *args, **kwargs)
                        return actual(inv, *args, **kwargs)
                    with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=hook), \
                            mock.patch.object(module.Inventory, "recheck", new=recheck):
                        with self.assertRaises(helper.ProviderError):
                            fixture.admit()
                    self.assertEqual((fixture.states / staging).exists(), staged)
                    self.assertEqual(fixture.successor.exists(), published)
                    self.assertEqual((fixture.states / temporary).exists(), temp)
                    self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
                    self.assertFalse(fixture.archive.exists())
                    self.assertEqual(len(os.listdir("/proc/self/fd")), baseline)

    def test_resource_failures_preserve_exact_completion_publications(self):
        module = helper._forward_state_module()
        actual = module.Inventory.recheck
        for boundary, accepted, archived, terminal in (
                ("acceptance-before", False, False, False),
                ("credential-cleanup-before", True, False, False),
                ("archive-before", True, False, False),
                ("terminal-before", True, True, False),
                ("pointer-unlink-before", True, True, True)):
            for code in (errno.EMFILE, errno.ENFILE):
                with self.subTest(boundary=boundary, errno=code):
                    fixture = self.fresh()
                    fixture.admit()
                    fixture.phase()
                    baseline = len(os.listdir("/proc/self/fd"))
                    armed = [False]
                    def hook(stage):
                        if stage == boundary:
                            armed[0] = True
                    def recheck(inv, *args, **kwargs):
                        if armed[0]:
                            with mock.patch.object(os, "open",
                                                   side_effect=OSError(code, "fictional exhaustion")):
                                return actual(inv, *args, **kwargs)
                        return actual(inv, *args, **kwargs)
                    with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=hook), \
                            mock.patch.object(module.Inventory, "recheck", new=recheck):
                        with self.assertRaises(helper.ProviderError):
                            fixture.complete()
                    self.assertEqual((fixture.successor / "forward-acceptance.json").exists(), accepted)
                    self.assertEqual(fixture.archive.exists(), archived)
                    self.assertEqual(fixture.origin.exists(), not archived)
                    self.assertEqual((fixture.successor / "terminal.json").exists(), terminal)
                    self.assertEqual(fixture.marker()["phase"], "finalizing")
                    self.assertEqual(len(os.listdir("/proc/self/fd")), baseline)

    def test_resource_failures_preserve_exact_phase_publications(self):
        module = helper._forward_state_module()
        actual = module.Inventory.recheck
        temporary = ".provider-transaction." + SUCCESSOR + ".forward-phase"
        for phase in ("verifying", "finalizing"):
            for after_write in (False, True):
                fixture = self.fresh()
                fixture.admit()
                if phase == "finalizing":
                    fixture.phase()
                original = fixture.pointer.read_bytes()
                baseline = len(os.listdir("/proc/self/fd"))
                calls = [0]
                def recheck(inv, *args, **kwargs):
                    calls[0] += 1
                    # Constructor, then the two phase-publication checkpoints.
                    if calls[0] == (3 if after_write else 2):
                        with mock.patch.object(os, "open",
                                               side_effect=OSError(errno.EMFILE, "fictional exhaustion")):
                            return actual(inv, *args, **kwargs)
                    return actual(inv, *args, **kwargs)
                with mock.patch.object(module.Inventory, "recheck", new=recheck):
                    with self.assertRaises(helper.ProviderError):
                        helper._forward_phase(str(fixture.states), SUCCESSOR, phase)
                self.assertEqual(fixture.pointer.read_bytes(), original)
                self.assertEqual((fixture.states / temporary).exists(), after_write)
                self.assertFalse(fixture.archive.exists())
                self.assertEqual(len(os.listdir("/proc/self/fd")), baseline)

    def test_constructor_exhaustion_blocks_before_any_adoption_publication(self):
        module = helper._forward_state_module()
        actual = module.Inventory.__init__
        fixture = self.fresh()
        baseline = len(os.listdir("/proc/self/fd"))
        def exhausted(inv, *args, **kwargs):
            with mock.patch.object(os, "dup", side_effect=OSError(errno.EMFILE, "fictional exhaustion")):
                actual(inv, *args, **kwargs)
        with mock.patch.object(module.Inventory, "__init__", new=exhausted):
            with self.assertRaises(helper.ProviderError):
                fixture.admit()
        self.unchanged(fixture)
        self.assertFalse(any(name.name.startswith((".provider-state.", ".provider-transaction." + SUCCESSOR))
                             for name in fixture.states.iterdir()))
        self.assertEqual(len(os.listdir("/proc/self/fd")), baseline)

    def test_new_foreign_entries_at_completion_boundaries_block_next_mutation(self):
        for boundary in ("acceptance-before", "credential-cleanup-before",
                         "archive-before", "terminal-before", "pointer-unlink-before"):
            with self.subTest(boundary=boundary):
                fixture = self.fresh()
                fixture.admit()
                fixture.phase()
                sidecar = fixture.states / ".smtp-transaction.current"
                def inject(stage):
                    if stage == boundary:
                        Fixture.write(sidecar, b"COMMITTED")
                with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=inject):
                    with self.assertRaises(helper.ProviderError):
                        fixture.complete()
                self.assertEqual(sidecar.read_bytes(), b"COMMITTED")
                self.assertTrue(fixture.pointer.exists())
                if boundary == "acceptance-before":
                    self.assertFalse((fixture.successor / "forward-acceptance.json").exists())

    def test_created_reused_disabled_full_finalize_and_retention(self):
        for disposition in ("created", "reused", "none"):
            with self.subTest(disposition=disposition):
                fixture = self.fresh(disposition)
                before = {role: (Path(path).read_bytes(), os.stat(path).st_ino)
                          for role, path in fixture.paths.items()}
                fallback_before = fixture.saved_identity(fixture.fallback)
                fixture.admit()
                self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
                self.assertEqual(fixture.marker()["durableDisposition"], disposition)
                receipt = (fixture.successor / "forward-adoption.json").read_bytes()
                witnesses = json.loads(receipt)["sourceWitnesses"]
                self.assertNotIn(str(fixture.fallback), [item["path"] for item in witnesses])
                self.assertNotIn("fallback-compose", [item["role"] for item in witnesses])
                self.assertNotIn(KEY.encode(), receipt)
                self.assertNotIn(b"fictional@example.invalid", receipt)
                helper._forward_revalidate(str(fixture.states), SUCCESSOR, encode([fixture.backend]))
                fixture.phase()
                fixture.complete()
                self.assertFalse(fixture.pointer.exists())
                self.assertFalse(fixture.origin.exists())
                self.assertTrue(fixture.archive.is_dir())
                self.assertFalse((fixture.archive / "terminal.json").exists())
                self.assertEqual((fixture.successor / "forward-adoption.json").read_bytes(), receipt)
                self.assertEqual(json.loads((fixture.successor / "terminal.json").read_bytes())["runKey"],
                                 SUCCESSOR)
                self.assertFalse(Path(helper._transaction(
                    str(fixture.credentials), helper.FORWARD_ORIGIN_KEY)).exists())
                for name, data in fixture.original_files.items():
                    self.assertEqual((fixture.archive / name).read_bytes(), data)
                self.assertEqual({role: (Path(path).read_bytes(), os.stat(path).st_ino)
                                  for role, path in fixture.paths.items()}, before)
                self.assertEqual(fixture.saved_identity(fixture.fallback), fallback_before)
                with contextlib.redirect_stdout(io.StringIO()):
                    helper._retention_check("", str(fixture.states))
                    helper._retention_delete(str(fixture.states), str(fixture.successor))
                self.assertFalse(fixture.successor.exists())
                self.assertTrue(fixture.archive.exists())
                if fixture.enabled:
                    self.assertEqual(os.stat(helper.HOST_CREDENTIAL_PATH).st_nlink, 1)

    def test_root_fallback_is_not_an_admission_source(self):
        fixture = self.fresh()
        fixture.fallback.unlink()
        fixture.admit()
        fixture.phase()
        fixture.complete()
        self.assertFalse(fixture.fallback.exists())
        self.assertTrue(fixture.archive.is_dir())

    def test_full_predecessor_image_identity_is_pinned(self):
        fixture = self.fresh()
        self.assertEqual(
            helper._forward_stopped(fixture.backend, fixture.original_files)["imageId"],
            OLD_IMAGE)
        self.assertEqual(fixture.backend["Id"], OLD)
        wrong_images = (
            OLD_IMAGE[:-1] + "1",  # Same correct prefix, different full identity.
            "sha256:8e40528c34d" + "b" * 53,  # Historical typo-derived fixture.
            OLD_IMAGE[:-1],
            OLD_IMAGE + "0",
        )
        for wrong in wrong_images:
            with self.subTest(image=wrong):
                fixture = self.fresh()
                fixture.backend["Image"] = wrong
                fixture.original_files["previous-image-id"] = (wrong + "\n").encode()
                with self.assertRaises(helper.ProviderError):
                    helper._forward_stopped(fixture.backend, fixture.original_files)
        fixture = self.fresh()
        fixture.original_files["previous-image-id"] = (wrong_images[0] + "\n").encode()
        with self.assertRaises(helper.ProviderError):
            helper._forward_stopped(fixture.backend, fixture.original_files)

    def test_preflight_failures_never_publish_or_adopt(self):
        mutations = {
            "running": lambda f: f.backend["State"].update(Running=True),
            "exit": lambda f: f.backend["State"].update(ExitCode=0),
            "finished": lambda f: f.backend["State"].update(FinishedAt="wrong"),
            "stopped-id": lambda f: f.backend.update(Id=NEW),
            "old-image": lambda f: f.backend.update(Image=NEW_IMAGE),
            "version-not-assumed": lambda f: f.old_image["Config"]["Labels"].update(
                {"org.opencontainers.image.version": "1.5.1"}),
            "hardening": lambda f: f.backend["HostConfig"].update(ReadonlyRootfs=False),
            "mount": lambda f: f.backend["Mounts"][0].update(Name="wrong"),
            "network": lambda f: f.backend["NetworkSettings"].update(Networks={}),
            "unrelated-env": lambda f: f.backend["Config"]["Env"].append("OTHER=changed"),
            "key": lambda f: f.backend["Config"]["Env"].append("LOCATIONIQ_KEY=wrong"),
            "activation": lambda f: f.backend["Config"]["Env"].extend(
                ["LOCATIONIQ_KEY=" + KEY, "GEOCODER_ENABLED=true"]),
            "platform": lambda f: f.target.update(Architecture="arm64"),
            "target-label": lambda f: f.target["Config"]["Labels"].update(
                {"org.opencontainers.image.revision": REVISION}),
            "target-render": lambda f: f.rendered["services"]["backend"].update(image="wrong"),
            "provider-render": lambda f: f.rendered["services"]["backend"]["environment"].update(
                APP_PUSH_PROVIDER_ENABLED="true"),
            "target-port": lambda f: f.rendered["services"]["backend"]["ports"][0].update(host_ip="0.0.0.0"),
            "missing-base": lambda f: Path(f.paths["original-base"]).unlink(),
            "snapshot-inode": lambda f: self.swap_same_bytes(Path(f.paths["production-env"])),
            "active-inode": lambda f: self.swap_same_bytes(Path(f.paths["active-runtime"])),
            "wrong-off": lambda f: Path(f.paths["production-env"]).write_bytes(
                f.target_env.replace(b"GEOCODER_ENABLED=false", b"GEOCODER_ENABLED=FALSE")),
            "foreign": lambda f: Fixture.write(f.origin / "foreign", b"x"),
            "hardlink": lambda f: os.link(f.origin / "previous-version", f.root / "alias"),
            "owner": lambda f: os.chown(f.origin / "previous-version", 10001, 10001),
            "mode": lambda f: (f.origin / "previous-version").chmod(0o644),
            "terminal-symlink": lambda f: (f.origin / "terminal.json").symlink_to("missing"),
            "smtp": lambda f: (f.states / ".smtp-transaction.current").symlink_to("missing"),
            "other-state": lambda f: Fixture.write(
                f.states / "555-1-final-deploy" / helper.OWNER_MARKER,
                helper._state_marker("555-1", "final-deploy")),
            "archive-exists": lambda f: f.archive.mkdir(mode=0o700),
            "wrong-phase": lambda f: f.pointer.write_bytes(encode(dict(f.marker(), phase="verifying"))),
        }
        for label, mutate in mutations.items():
            with self.subTest(case=label):
                fixture = self.fresh()
                mutate(fixture)
                with self.assertRaises((helper.ProviderError, OSError, ValueError)):
                    fixture.admit()
                self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
                self.assertFalse(fixture.successor.exists())

    @staticmethod
    def swap_same_bytes(path):
        replacement = path.with_name(path.name + ".swap")
        Fixture.write(replacement, path.read_bytes())
        os.replace(replacement, path)

    def test_receipt_strict_schema_and_immutable_publication(self):
        fixture = self.fresh()
        fixture.admit()
        raw = (fixture.successor / "forward-adoption.json").read_bytes()
        adoption = json.loads(raw)
        for mutate in (
            lambda v: v.update(extra=True),
            lambda v: v.pop("stoppedWitness"),
            lambda v: v["sourceWitnesses"].pop(),
            lambda v: v["stoppedWitness"]["staticInspect"]["hardening"].update(extra=True),
            lambda v: v["stoppedWitness"]["staticInspect"].update(cmd=["override"]),
            lambda v: v["plannedArchive"].update(path="/tmp/archive"),
            lambda v: v["originalMarker"].update(bytesBase64="not-base64"),
            lambda v: v.update(successorRunKey="99999999999-2"),
        ):
            with self.subTest(mutate=mutate):
                value = copy.deepcopy(adoption)
                mutate(value)
                with self.assertRaises(helper.ProviderError):
                    helper._validate_forward_adoption(encode(value), SUCCESSOR)
        with self.assertRaises(helper.ProviderError):
            helper._validate_forward_adoption(raw.replace(
                b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1', 1), SUCCESSOR)
        with self.assertRaises((helper.ProviderError, OSError)):
            fixture.admit()
        self.assertEqual((fixture.successor / "forward-adoption.json").read_bytes(), raw)

    def test_adoption_crashes_keep_one_authoritative_pointer_and_never_replay(self):
        stages = ("state-staged", "state-published", "pointer-ready",
                  "pointer-renamed", "pointer-replaced")
        for stage in stages:
            with self.subTest(stage=stage):
                fixture = self.fresh()
                def crash(actual):
                    if actual == stage:
                        raise RuntimeError(stage)
                with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=crash):
                    with self.assertRaises(RuntimeError):
                        fixture.admit()
                successor = stage in ("pointer-renamed", "pointer-replaced")
                self.assertEqual(fixture.marker()["runKey"],
                                 SUCCESSOR if successor else helper.FORWARD_ORIGIN_KEY)
                self.assertTrue(fixture.origin.exists())
                with self.assertRaises((helper.ProviderError, OSError)):
                    fixture.admit()

    def test_finalization_crashes_preserve_audit_pointer_or_durable_commit(self):
        stages = (
            "acceptance-before", "acceptance-file-synced", "acceptance-directory-synced",
            "credential-cleanup-before", "credential-cleanup-after", "archive-before",
            "archive-renamed", "archive-source-parent-sync-before", "archive-source-parent-synced",
            "archive-target-parent-sync-before", "archive-target-parent-synced",
            "terminal-before", "terminal-file-synced", "terminal-directory-synced",
            "pointer-unlink-before", "pointer-unlinked", "pointer-unlink-parent-synced",
        )
        for disposition in ("created", "reused", "none"):
            for stage in stages:
                with self.subTest(disposition=disposition, stage=stage):
                    fixture = self.fresh(disposition)
                    fixture.admit()
                    fixture.phase()
                    def crash(actual):
                        if actual == stage:
                            raise RuntimeError(stage)
                    with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=crash):
                        with self.assertRaises(RuntimeError):
                            fixture.complete()
                    if fixture.pointer.exists():
                        self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
                    else:
                        self.assertTrue((fixture.successor / "terminal.json").exists())
                        self.assertTrue(fixture.archive.exists())
                    self.assertTrue(fixture.origin.exists() or fixture.archive.exists())
                    with self.assertRaises((helper.ProviderError, OSError)):
                        fixture.complete()
                    if fixture.enabled:
                        self.assertTrue(Path(helper.HOST_CREDENTIAL_PATH).exists())

    def test_retention_rejects_planned_only_drift_substitution_and_residual_transaction(self):
        for case in ("planned", "archive-drift", "archive-substitution", "residual-tx",
                     "digest", "tuple", "terminal", "acceptance-missing"):
            with self.subTest(case=case):
                fixture = self.fresh()
                fixture.admit()
                fixture.phase()
                fixture.complete()
                if case == "planned":
                    os.rename(fixture.archive, fixture.origin)
                elif case == "archive-drift":
                    (fixture.archive / "previous-version").write_bytes(b"1.5.1\n")
                elif case == "archive-substitution":
                    os.rename(fixture.archive, fixture.archive_parent / "saved")
                    shutil.copytree(fixture.archive_parent / "saved", fixture.archive)
                elif case == "residual-tx":
                    (fixture.credentials / (".transaction-" + helper.FORWARD_ORIGIN_KEY)).mkdir(mode=0o700)
                elif case in ("digest", "tuple"):
                    path = fixture.successor / "forward-acceptance.json"
                    value = json.loads(path.read_bytes())
                    if case == "digest":
                        value["adoptionSha256"] = "0" * 64
                    else:
                        value["target"]["version"] = "1.6.1"
                    path.write_bytes(encode(value))
                elif case == "terminal":
                    path = fixture.successor / "terminal.json"
                    value = json.loads(path.read_bytes())
                    value["providerEnabled"] = True
                    path.write_bytes(encode(value))
                else:
                    (fixture.successor / "forward-acceptance.json").unlink()
                with self.assertRaises(helper.ProviderError):
                    helper._retention_check("", str(fixture.states))
                self.assertTrue(fixture.successor.exists())

    def test_credential_alias_rejects_drift_and_cannot_rollback(self):
        for disposition in ("created", "reused"):
            fixture = self.fresh(disposition)
            fixture.admit()
            fixture.phase()
            with self.assertRaises(helper.ProviderError):
                helper._verify(SUCCESSOR, "", encode([fixture.candidate]),
                               "rollback", str(fixture.states))
            with self.assertRaises(helper.ProviderError):
                helper._finish(SUCCESSOR, str(fixture.states), "",
                               "rolled-back", encode([fixture.candidate]))
            Path(helper.HOST_CREDENTIAL_PATH).chmod(0o640)
            with self.assertRaises(helper.ProviderError):
                fixture.complete()
            self.assertTrue(fixture.pointer.exists())
            self.assertTrue(fixture.origin.exists())


    def test_injected_fsync_failures_never_unblock_an_unsafe_state(self):
        def count_syncs(operation):
            count = 0
            real_sync = os.fsync
            def counted(fd):
                nonlocal count
                count += 1
                return real_sync(fd)
            with mock.patch.object(helper.os, "fsync", side_effect=counted):
                operation()
            return count

        fixture = self.fresh()
        adoption_syncs = count_syncs(fixture.admit)
        fixture.phase()
        completion_syncs = count_syncs(fixture.complete)
        self.assertGreater(adoption_syncs, 10)
        self.assertGreater(completion_syncs, 5)
        for operation_name, total in (("adopt", adoption_syncs), ("complete", completion_syncs)):
            for failed_sync in range(1, total + 1):
                with self.subTest(operation=operation_name, fsync=failed_sync):
                    fixture = self.fresh()
                    if operation_name == "complete":
                        fixture.admit()
                        fixture.phase()
                    count = 0
                    real_sync = os.fsync
                    def interrupted(fd):
                        nonlocal count
                        count += 1
                        if count == failed_sync:
                            raise OSError("fixture fsync interruption")
                        return real_sync(fd)
                    with mock.patch.object(helper.os, "fsync", side_effect=interrupted):
                        with self.assertRaises(OSError):
                            (fixture.admit if operation_name == "adopt" else fixture.complete)()
                    if fixture.pointer.exists():
                        self.assertIn(fixture.marker()["runKey"], (helper.FORWARD_ORIGIN_KEY, SUCCESSOR))
                    else:
                        self.assertTrue((fixture.successor / "terminal.json").exists())
                        self.assertTrue(fixture.archive.exists())
                    self.assertTrue(fixture.origin.exists() or fixture.archive.exists())

    def test_adoption_races_are_revalidated_before_pointer_replacement(self):
        for case in ("byte", "inode", "pointer", "credential"):
            fixture = self.fresh("created" if case == "credential" else "none")
            def race(stage):
                if stage == "pointer-ready":
                    if case == "byte":
                        (fixture.origin / "previous-version").write_bytes(b"1.5.1\n")
                    elif case == "inode":
                        self.swap_same_bytes(Path(fixture.paths["active-compose"]))
                    elif case == "pointer":
                        fixture.pointer.write_bytes(fixture.pointer.read_bytes() + b" ")
                    else:
                        Path(helper.HOST_CREDENTIAL_PATH).chmod(0o640)
            with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=race):
                with self.assertRaises(helper.ProviderError):
                    fixture.admit()
            self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
            self.assertTrue(fixture.origin.exists())
            self.assertFalse(fixture.archive.exists())

    def test_acl_lock_alias_reflection_and_candidate_drift_reject(self):
        fixture = self.fresh()
        real_acl = helper._acl_is_safe
        def reject_origin(path, **kwargs):
            if str(path) == str(fixture.origin):
                helper._fail("recovery")
            return real_acl(path, **kwargs)
        with mock.patch.object(helper, "_acl_is_safe", side_effect=reject_origin):
            with self.assertRaises(helper.ProviderError):
                fixture.admit()
        self.unchanged(fixture)
        fixture = self.fresh()
        helper.fcntl.flock(9, helper.fcntl.LOCK_UN)
        self.swap_same_bytes(fixture.states / ".deploy.lock")
        with self.assertRaises(helper.ProviderError):
            fixture.admit()
        self.unchanged(fixture)
        fixture = self.fresh()
        fixture.backend["NetworkSettings"]["Networks"]["meet-production_default"]["Aliases"] = [KEY]
        with self.assertRaises(helper.ProviderError):
            fixture.admit()
        self.unchanged(fixture)
        for mutation in ("key", "id", "files", "provider"):
            fixture = self.fresh()
            fixture.admit()
            fixture.phase()
            if mutation == "key":
                fixture.candidate["Config"]["Env"].append("LOCATIONIQ_KEY=other")
            elif mutation == "id":
                fixture.candidate["Id"] = OLD
            elif mutation == "files":
                self.swap_same_bytes(Path(fixture.paths["active-compose"]))
            else:
                fixture.candidate["Config"]["Env"].append("APP_PUSH_DISPATCH_ENABLED=true")
            with self.assertRaises(helper.ProviderError):
                fixture.complete()
            self.assertTrue(fixture.pointer.exists())
            self.assertTrue(fixture.origin.exists())
            self.assertFalse((fixture.successor / "forward-acceptance.json").exists())


class HistoricalOriginalTests(FixtureTests):
    """Real Linux ownership/ACL/inode behavior, with read-only reject evidence."""

    def historical(self):
        fixture = self.fresh()
        fixture.historical_original()
        return fixture

    @staticmethod
    def inventory(root):
        result = {}
        for path in (root, *root.rglob("*")):
            info = path.lstat()
            identity = helper._forward_identity_from_stat(info)
            data = path.read_bytes() if stat.S_ISREG(info.st_mode) else None
            result[str(path.relative_to(root))] = (identity, data, tuple(sorted(
                (name, os.getxattr(path, name, follow_symlinks=False))
                for name in os.listxattr(path, follow_symlinks=False))))
        return result

    def rejected_unchanged(self, fixture, operation=None):
        before = self.inventory(fixture.root)
        with self.assertRaises((helper.ProviderError, OSError)):
            (operation or fixture.admit)()
        self.assertEqual(self.inventory(fixture.root), before)

    @staticmethod
    def owner_write(path):
        # Owners may retain an open fd even under root-private ancestry.
        fd = os.open(path, os.O_WRONLY)
        try:
            subprocess.run([sys.executable, "-B", "-c",
                            "import os,sys; os.setgid(1001); os.setuid(1001); "
                            "os.pwrite(int(sys.argv[1]), b'X', 0)",
                            str(fd)], pass_fds=(fd,), check=True, timeout=10)
        finally:
            os.close(fd)

    @staticmethod
    def acl(path, default=False):
        # Linux POSIX ACL v2: named UID 1001, not a mock of the xattr API.
        mode = stat.S_IMODE(path.stat().st_mode)
        entries = ((1, mode >> 6 & 7, 0xffffffff), (2, 4, 1001),
                   (4, 0, 0xffffffff), (16, mode >> 3 & 7, 0xffffffff),
                   (32, mode & 7, 0xffffffff))
        os.setxattr(path, "system.posix_acl_" + ("default" if default else "access"),
                    struct.pack("<I", 2) + b"".join(
                        struct.pack("<HHI", *entry) for entry in entries))
        assert stat.S_IMODE(path.stat().st_mode) == mode

    def test_historical_all_boundaries_and_retention_preserve_contract(self):
        for disposition in ("none", "created", "reused"):
            with self.subTest(disposition=disposition):
                fixture = self.fresh(disposition)
                fixture.historical_original()
                before = self.inventory(fixture.app)
                fixture.admit()
                receipt = (fixture.successor / "forward-adoption.json").read_bytes()
                witness = next(item for item in json.loads(receipt)["sourceWitnesses"]
                               if item["role"] == "original-base")
                self.assertEqual((witness["identity"]["uid"], witness["identity"]["gid"]),
                                 (1001, 1001))
                with contextlib.redirect_stdout(io.StringIO()):
                    helper._forward_revalidate(str(fixture.states), SUCCESSOR,
                                               encode([fixture.backend]))
                fixture.phase()
                fixture.complete()
                with contextlib.redirect_stdout(io.StringIO()):
                    helper._retention_check("", str(fixture.states))
                self.assertEqual(self.inventory(fixture.app), before)
                self.assertEqual((fixture.archive / "config.base-compose.yml.identity").read_bytes(),
                                 fixture.original_files["config.base-compose.yml.identity"])

    def test_only_exact_owner_mode_and_fixed_path_are_eligible_even_with_saved_match(self):
        for uid, gid, mode in ((1001, 1001, 0o600), (1002, 1002, 0o644),
                               (1001, 0, 0o644), (0, 1001, 0o644),
                               (1001, 1001, 0o640), (1001, 1001, 0o666)):
            with self.subTest(uid=uid, gid=gid, mode=mode):
                fixture = self.historical()
                path = Path(fixture.paths["original-base"])
                os.chown(path, uid, gid)
                path.chmod(mode)
                name = "config.base-compose.yml.identity"
                fixture.original_files[name] = fixture.saved_identity(path)
                Fixture.write(fixture.origin / name, fixture.original_files[name])
                if (uid, gid, mode) == (1001, 1001, 0o600):
                    fixture.admit()
                else:
                    self.rejected_unchanged(fixture)
        fixture = self.historical()
        for path in (fixture.paths["reviewed-base"], str(fixture.fallback),
                     str(fixture.app) + "/../base"):
            with self.assertRaises(helper.ProviderError):
                helper._forward_read_original_base(path, str(fixture.origin),
                                                   fixture.original_files)

    def test_exact_byte_budget_and_over_budget_are_bounded(self):
        fixture = self.historical()
        path = Path(fixture.paths["original-base"])
        content = b"x" * helper.MAX_WITNESS_BYTES
        path.write_bytes(content)
        for name, data in (("config.base-compose.yml", content),
                           ("config.base-compose.yml.identity", fixture.saved_identity(path))):
            Fixture.write(fixture.origin / name, data)
            fixture.original_files[name] = data
        identity, actual = helper._forward_read_original_base(
            str(path), str(fixture.origin), fixture.original_files)
        self.assertEqual(actual, content)
        self.assertEqual(identity["size"], helper.MAX_WITNESS_BYTES)
        with path.open("ab") as stream:
            stream.write(b"x")
        self.rejected_unchanged(fixture, lambda: helper._forward_read_original_base(
            str(path), str(fixture.origin), fixture.original_files))

    def test_every_saved_field_and_malformed_record_reject_readonly(self):
        for index in range(9):
            with self.subTest(field=index):
                fixture = self.historical()
                saved = fixture.origin / "config.base-compose.yml.identity"
                fields = saved.read_text().rstrip("\n").split(":")
                fields[index] = ("0" * 64 if index == 8 else str(int(fields[index]) + 1))
                saved.write_bytes((":".join(fields) + "\n").encode())
                self.rejected_unchanged(fixture)
        for shape in ("truncated", "extra", "newline", "garbage"):
            with self.subTest(shape=shape):
                fixture = self.historical()
                saved = fixture.origin / "config.base-compose.yml.identity"
                data = saved.read_bytes()
                saved.write_bytes({"truncated": data[:-20], "extra": data[:-1] + b":0\n",
                                   "newline": data[:-1], "garbage": b"invalid\n"}[shape])
                self.rejected_unchanged(fixture)

    def test_leaf_metadata_bytes_and_type_hostility_reject_readonly(self):
        cases = ("inode", "uid", "gid", "mode", "hardlink", "size", "mtime",
                 "bytes", "symlink", "fifo", "socket", "device", "budget")
        for case in cases:
            with self.subTest(case=case):
                fixture = self.historical()
                path = Path(fixture.paths["original-base"])
                if case == "inode":
                    ForwardTests.swap_same_bytes(path)
                    os.chown(path, 1001, 1001)
                    path.chmod(0o644)
                elif case == "uid":
                    os.chown(path, 1002, 1001)
                elif case == "gid":
                    os.chown(path, 1001, 1002)
                elif case == "mode":
                    path.chmod(0o600)
                elif case == "hardlink":
                    os.link(path, fixture.root / "alias")
                elif case == "mtime":
                    info = path.stat()
                    os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1))
                elif case in ("size", "bytes"):
                    path.write_bytes(b"services: []\n" if case == "bytes" else b"larger\n" * 4)
                elif case == "budget":
                    with path.open("wb") as stream:
                        stream.truncate(helper.MAX_WITNESS_BYTES + 1)
                else:
                    path.unlink()
                    if case == "symlink":
                        path.symlink_to(fixture.paths["reviewed-base"])
                    elif case == "fifo":
                        os.mkfifo(path)
                    elif case == "socket":
                        with socket.socket(socket.AF_UNIX) as sock:
                            sock.bind(str(path))
                    else:
                        os.mknod(path, stat.S_IFCHR | 0o600, os.makedev(1, 3))
                self.rejected_unchanged(fixture)

    def test_strict_roles_and_untrusted_saved_authority_reject_readonly(self):
        for role in ("original-base", "reviewed-base", "production-env",
                     "active-compose", "active-runtime", "lock"):
            with self.subTest(role=role):
                fixture = self.historical()
                path = (fixture.states / ".deploy.lock" if role == "lock"
                        else Path(fixture.paths[role]))
                os.chown(path, 1001, 1001)
                with self.assertRaises(helper.ProviderError):
                    helper._forward_read_external(str(path))
                if role != "original-base":
                    self.rejected_unchanged(fixture)
        for name in (helper.OWNER_MARKER, "config.base-compose.yml",
                     "config.base-compose.yml.identity"):
            for mutation in ("owner", "gid", "mode", "symlink"):
                with self.subTest(authority=name, mutation=mutation):
                    fixture = self.historical()
                    path = fixture.origin / name
                    if mutation == "owner":
                        os.chown(path, 1001, 1001)
                    elif mutation == "gid":
                        os.chown(path, 0, 1001)
                    elif mutation == "mode":
                        path.chmod(0o644)
                    else:
                        data = path.read_bytes()
                        path.unlink()
                        Fixture.write(fixture.root / "untrusted-saved", data)
                        path.symlink_to(fixture.root / "untrusted-saved")
                    self.rejected_unchanged(fixture)

    def test_ancestor_trust_and_real_access_default_acls_reject(self):
        for case in ("symlink", "writable", "owner", "access", "default",
                     "leaf-access", "saved-access", "unsupported"):
            with self.subTest(case=case):
                fixture = self.historical()
                path = Path(fixture.paths["original-base"])
                parent = path.parent
                if case == "symlink":
                    saved = parent.with_name("moved")
                    parent.rename(saved)
                    parent.symlink_to(saved, target_is_directory=True)
                elif case == "writable":
                    parent.chmod(0o720)
                elif case == "owner":
                    os.chown(parent, 1001, 1001)
                elif case in ("access", "default"):
                    self.acl(parent, default=case == "default")
                elif case == "leaf-access":
                    self.acl(path)
                elif case == "saved-access":
                    self.acl(fixture.origin / "config.base-compose.yml.identity")
                if case == "unsupported":
                    with mock.patch.object(helper.os, "getxattr",
                                           side_effect=OSError(errno.ENOTSUP, "fixture")):
                        self.rejected_unchanged(fixture)
                else:
                    self.rejected_unchanged(fixture)

    def test_forged_receipt_role_path_snapshot_and_identity_reject(self):
        for case in ("role", "path", "fallback", "traversal", "snapshotRef", "uid", "gid", "nlink"):
            with self.subTest(case=case):
                fixture = self.historical()
                fixture.admit()
                value = json.loads((fixture.successor / "forward-adoption.json").read_bytes())
                witness = next(item for item in value["sourceWitnesses"]
                               if item["role"] == "original-base")
                if case == "role":
                    witness["role"] = "reviewed-base"
                elif case in ("path", "fallback", "traversal"):
                    witness["path"] = {"path": fixture.paths["reviewed-base"],
                                       "fallback": str(fixture.fallback),
                                       "traversal": str(fixture.app) + "/../base"}[case]
                    value["sourceWitnesses"].sort(key=lambda item: item["path"])
                elif case == "snapshotRef":
                    witness["snapshotRef"] = "candidate-active-compose.yml"
                else:
                    witness["identity"][case] += 1
                with self.assertRaises(helper.ProviderError):
                    helper._validate_forward_adoption(encode(value), SUCCESSOR)

    def test_owner_writes_fail_revalidate_complete_and_pointer_publication(self):
        for boundary in ("revalidate", "complete", "pointer-ready"):
            with self.subTest(boundary=boundary):
                fixture = self.historical()
                path = Path(fixture.paths["original-base"])
                if boundary == "pointer-ready":
                    def write(stage):
                        if stage == boundary:
                            self.owner_write(path)
                    with mock.patch.object(helper, "_forward_adopt_boundary", side_effect=write):
                        with self.assertRaises(helper.ProviderError):
                            fixture.admit()
                    self.assertEqual(fixture.marker()["runKey"], helper.FORWARD_ORIGIN_KEY)
                else:
                    fixture.admit()
                    if boundary == "complete":
                        fixture.phase()
                    self.owner_write(path)
                    operation = (fixture.complete if boundary == "complete" else lambda:
                                 helper._forward_revalidate(str(fixture.states), SUCCESSOR,
                                                            encode([fixture.backend])))
                    self.rejected_unchanged(fixture, operation)
                    self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
                self.assertFalse(fixture.archive.exists())
                self.assertFalse((fixture.successor / "forward-acceptance.json").exists())

    def test_receipt_cannot_rebase_saved_authority_on_revalidation(self):
        fixture = self.historical()
        fixture.admit()
        path = Path(fixture.paths["original-base"])
        # Restore the same bytes but alter ctime using the real owner's fd.
        self.owner_write(path)
        path.write_bytes(fixture.original_files["config.base-compose.yml"])
        receipt_path = fixture.successor / "forward-adoption.json"
        receipt = json.loads(receipt_path.read_bytes())
        witness = next(item for item in receipt["sourceWitnesses"]
                       if item["role"] == "original-base")
        witness["identity"] = helper._forward_identity_from_stat(path.stat())
        receipt_path.write_bytes(encode(receipt))
        helper._validate_forward_adoption(receipt_path.read_bytes(), SUCCESSOR)
        self.rejected_unchanged(fixture, lambda: helper._forward_revalidate(
            str(fixture.states), SUCCESSOR, encode([fixture.backend])))
        self.assertEqual((fixture.origin / "config.base-compose.yml.identity").read_bytes(),
                         fixture.original_files["config.base-compose.yml.identity"])

    def test_adopt_request_cannot_supply_replacement_saved_authority(self):
        fixture = self.historical()
        with mock.patch.object(helper, "_forward_adopt") as capture:
            fixture.admit()
        request = json.loads(capture.call_args.args[1])
        path = Path(fixture.paths["original-base"])
        self.owner_write(path)
        path.write_bytes(fixture.original_files["config.base-compose.yml"])
        receipt = json.loads(base64.b64decode(request["adoptionReceiptBase64"]))
        witness = next(item for item in receipt["sourceWitnesses"]
                       if item["role"] == "original-base")
        witness["identity"] = helper._forward_identity_from_stat(path.stat())
        request["adoptionReceiptBase64"] = base64.b64encode(encode(receipt)).decode()
        request["snapshots"]["config.base-compose.yml.identity"] = base64.b64encode(
            fixture.saved_identity(path)).decode()
        self.rejected_unchanged(fixture, lambda: helper._forward_adopt(
            str(fixture.states), encode(request)))
        self.unchanged(fixture)

    def test_descriptor_pinning_rejects_read_and_ancestor_swaps_without_leaks(self):
        for case in ("owner-write", "leaf-rename", "ancestor-symlink", "ancestor-rename"):
            with self.subTest(case=case):
                fixture = self.historical()
                path = Path(fixture.paths["original-base"])
                original_read = helper._read_fd_bounded
                fired = False
                def raced(fd, limit):
                    nonlocal fired
                    data = original_read(fd, limit)
                    if not fired and os.fstat(fd).st_uid == 1001:
                        fired = True
                        if case == "owner-write":
                            self.owner_write(path)
                        elif case == "leaf-rename":
                            ForwardTests.swap_same_bytes(path)
                            os.chown(path, 1001, 1001)
                            path.chmod(0o644)
                        else:
                            parent = path.parent
                            moved = parent.with_name("moved")
                            parent.rename(moved)
                            if case == "ancestor-symlink":
                                parent.symlink_to(moved, target_is_directory=True)
                            else:
                                parent.mkdir(mode=0o700)
                                Fixture.write(path, data)
                    return data
                fds = len(os.listdir("/proc/self/fd"))
                with mock.patch.object(helper, "_read_fd_bounded", side_effect=raced):
                    with self.assertRaises((helper.ProviderError, OSError)):
                        fixture.admit()
                self.assertTrue(fired)
                self.assertEqual(len(os.listdir("/proc/self/fd")), fds)
                self.unchanged(fixture)


FAKE_DOCKER = r'''#!/usr/bin/env python3
import base64, json, os, pathlib, re, stat, subprocess, sys
root = pathlib.Path(os.environ["FORWARD_FIXTURE"])
args = sys.argv[1:]
explicit = args[:1] == ["--host=unix:///var/run/docker.sock"]
if explicit:
    args.pop(0)
with (root / "trace").open("a") as stream:
    stream.write(json.dumps({"argv": args, "explicit": explicit,
                            "host": os.environ.get("DOCKER_HOST"),
                            "context": os.environ.get("DOCKER_CONTEXT")}) + "\n")
failure = os.environ.get("FORWARD_FAILURE", "")
if args[:2] == ["context", "inspect"]:
    if failure == "pin":
        sys.exit(1)
    print("tcp://unexpected:2375" if failure == "endpoint" else "unix:///var/run/docker.sock")
    sys.exit()
if args == ["context", "show"]:
    print("default")
    sys.exit()
if os.environ.get("DOCKER_HOST") != "unix:///var/run/docker.sock" or os.environ.get("DOCKER_CONTEXT"):
    sys.exit(91)
data = json.loads((root / "fake-data").read_text())
started = (root / "started").exists()
backend = data["candidate"] if started else data["backend"]
if started and failure == "candidate-key":
    backend["Config"]["Env"].append("LOCATIONIQ_KEY=wrong")
if started and failure == "candidate-identity":
    backend["Id"] = "9" * 64
def output(value):
    if "--format" not in args:
        print(json.dumps([value]))
        return
    fmt = args[args.index("--format") + 1]
    if "range .Config.Env" in fmt:
        print("\n".join(value["Config"]["Env"]))
    elif "range .Mounts" in fmt:
        destination = "/data/uploads" if "/data/uploads" in fmt else "/var/lib/postgresql/data"
        for mount in value["Mounts"]:
            if mount["Destination"] == destination:
                print(mount["Type"] + "|" + mount.get("Name", ""))
    elif "range $port" in fmt:
        print("127.0.0.1:8080")
    elif "index .Config.Labels" in fmt:
        print(value["Config"]["Labels"][re.search(r'"([^"]+)"', fmt).group(1)])
    else:
        path = fmt.replace("{{json ", "").replace("{{", "").replace("}}", "").strip().lstrip(".")
        item = value
        for key in path.split("."):
            item = item[key]
        if fmt.startswith("{{json "):
            print(json.dumps(item))
        elif isinstance(item, bool):
            print(str(item).lower())
        else:
            print(item)
if args[:2] == ["image", "inspect"]:
    ref = args[2]
    value = data["previousImage"] if ref == data["backend"]["Image"] else data["targetImage"]
    if failure == "platform" and "9178741b" in ref:
        value["Id"] = "sha256:" + "0" * 64
    output(value)
elif args[:1] == ["inspect"]:
    identifier = args[1]
    output(data["postgres"] if identifier == data["postgres"]["Id"] else backend)
elif args[:2] == ["volume", "inspect"]:
    print(json.dumps(data["volumes"]))
elif args[:1] == ["exec"]:
    if args[1] == data["backend"]["Id"]:
        sys.exit(92)
    if args[-2:] in (["id", "-u"], ["id", "-g"]):
        print("10001")
elif args[:1] == ["port"]:
    pass
elif args[:1] == ["stop"]:
    if args[1:] != [backend["Id"]] or args[1] == data["backend"]["Id"] or not explicit:
        sys.exit(93)
    if failure == "stop":
        sys.exit(1)
elif args[:1] == ["compose"]:
    operation = next((arg for arg in args if arg in ("ps", "config", "up", "port", "stop")), "")
    if failure == "predecessor" and operation == "ps" and args[-1:] == ["backend"]:
        sys.exit(1)
    if failure == "rendered-witness" and operation == "config":
        sys.exit(1)
    inputs = []
    if operation == "up" and failure == "owner-write-after-validation":
        path = data["originalBase"]
        fd = os.open(path, os.O_WRONLY)
        subprocess.run([sys.executable, "-B", "-c",
                        "import os,sys; os.setgid(1001); os.setuid(1001); "
                        "os.pwrite(int(sys.argv[1]), b'X', 0)", str(fd)],
                       pass_fds=(fd,), check=True, timeout=10)
        os.close(fd)
    for index, arg in enumerate(args):
        if arg != "-f":
            continue
        path = pathlib.Path(args[index + 1])
        info = path.stat()
        inputs.append({"path": str(path), "uid": info.st_uid, "gid": info.st_gid,
                       "mode": stat.S_IMODE(info.st_mode), "nlink": info.st_nlink,
                       "bytes": base64.b64encode(path.read_bytes()).decode()})
    with (root / "consumer-trace").open("a") as stream:
        stream.write(json.dumps({"operation": operation, "inputs": inputs}) + "\n")
    if operation == "ps":
        print(data["postgres"]["Id"] if args[-1] == "postgres" else backend["Id"])
    elif operation == "config":
        print(json.dumps(data["rendered"]))
    elif operation == "port":
        print("127.0.0.1:8080")
    elif operation == "up":
        if args[args.index("up"):] != ["up", "-d", "--no-deps", "--no-build",
               "--pull", "never", "--force-recreate", "--wait", "--wait-timeout", "180", "backend"]:
            sys.exit(94)
        (root / "started").touch()
        if failure == "recreate":
            sys.exit(1)
        if failure == "signal":
            import signal
            os.kill(os.getppid(), signal.SIGTERM)
            sys.exit(1)
    else:
        sys.exit(95)
else:
    sys.exit(96)
'''

FAKE_CURL = r'''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if os.environ.get("FORWARD_FAILURE") in ("public", "stop", "identity-uncertain"):
    import pathlib
    pathlib.Path(os.environ["FORWARD_FIXTURE"], "public-failed").touch()
    sys.exit(1)
url = next(arg for arg in args if arg.startswith("http"))
if "--dump-header" in args:
    print("HTTP/1.1 308 Permanent Redirect\r\nLocation: https://fixture.invalid/meetings\r\n\r\n308", end="")
elif "--write-out" in args:
    if "/admin/" in url:
        print("403", end="")
    elif "/actuator" in url:
        print("404", end="")
    else:
        print("[]\n200", end="")
else:
    print("[]")
'''


class ShellIntegrationTests(FixtureTests):
    """Actual release helper, Compose wrapper and healthy runtime invariant code."""

    def run_shell(self, disposition="none", failure="", overrides=None, historical=False,
                  workflow_route=False):
        fixture = self.fresh(disposition)
        if historical:
            fixture.historical_original()
        stage = Path(fixture.paths["reviewed-base"]).parent / "scripts"
        stage.mkdir(mode=0o700)
        for name in (
            "deploy-test-vps-provider-release.sh", "test-vps-provider-credential.py",
            "test-vps-runtime-invariants.sh", "test-vps-locationiq-pending-off.py",
            "test_vps_file_trust.py", "configure-test-vps-locationiq.py",
            "test_vps_state_admission.py",
            "production-compose.sh", "update-production-release.sh"):
            text = (SCRIPTS / name).read_text()
            # Only path constants are remapped in the private fixture copy.
            text = text.replace("/var/lib/meet-production/credentials", str(fixture.credentials))
            text = text.replace("/var/lib/meet-production", str(fixture.active))
            text = text.replace("/opt/meet-backend", str(fixture.app))
            text = text.replace("/var/lib/meet-test-vps-incident-archive",
                                str(fixture.archive_parent))
            Fixture.write(stage / name, text.encode(), 0o755)
        postgres = {
            "Id": "3" * 64, "Image": "sha256:" + "4" * 64,
            "State": {"Running": True, "Health": {"Status": "healthy"}},
            "Config": {"Labels": {"com.docker.compose.project": "meet-production",
                                 "com.docker.compose.service": "postgres"}},
            "HostConfig": {"PortBindings": {}},
            "Mounts": [{"Type": "volume", "Name": "meet-production_postgres_data",
                        "Destination": "/var/lib/postgresql/data"}],
            "NetworkSettings": {"Networks": {"meet-production_default": {}}},
        }
        if failure == "postgres":
            postgres["State"]["Health"]["Status"] = "unhealthy"
        Fixture.write(fixture.root / "fake-data", encode({
            "backend": fixture.backend, "candidate": fixture.candidate,
            "previousImage": fixture.old_image, "targetImage": fixture.target,
            "postgres": postgres, "rendered": fixture.rendered,
            "volumes": [{"Name": "meet-production_uploads_data"},
                        {"Name": "meet-production_postgres_data"}],
            "originalBase": fixture.paths["original-base"],
        }))
        bin_dir = fixture.root / "bin"
        Fixture.write(bin_dir / "docker", FAKE_DOCKER.encode(), 0o755)
        public_url = ("https://api.whysoezzy.online" if workflow_route
                      else "https://fixture.invalid")
        Fixture.write(bin_dir / "curl",
                      FAKE_CURL.replace("https://fixture.invalid", public_url).encode(), 0o755)
        if failure == "adoption-jq":
            real_jq = shutil.which("jq")
            if real_jq is None:
                self.fail("jq is required for the adoption-boundary fixture")
            Fixture.write(bin_dir / "jq", (
                "#!/usr/bin/env python3\n"
                "import os, sys\n"
                "if '.providerEnabled | tostring' in sys.argv:\n"
                "    sys.exit(42)\n"
                f"os.execv({real_jq!r}, [{real_jq!r}, *sys.argv[1:]])\n"
            ).encode(), 0o755)
        if failure in ("native-adoption", "revalidation", "forward-complete"):
            real_python = shutil.which("python3")
            if real_python is None:
                self.fail("python3 is required for the native-boundary fixture")
            Fixture.write(bin_dir / "python3", (
                f"#!{real_python}\n"
                "import os, pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "command = {'native-adoption': 'forward-adopt', "
                "'revalidation': 'forward-revalidate', "
                "'forward-complete': 'forward-complete'}.get("
                "os.environ.get('FORWARD_FAILURE'))\n"
                "if len(args) > 1 and pathlib.Path(args[1]).name == "
                "'test-vps-provider-credential.py' and command in args:\n"
                "    sys.exit(42)\n"
                f"os.execv({real_python!r}, [{real_python!r}, *args])\n"
            ).encode(), 0o755)
        env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                   FORWARD_FIXTURE=str(fixture.root), FORWARD_FAILURE=failure,
                   TEST_VPS_STATE_ROOT=str(fixture.states), PYTHONDONTWRITEBYTECODE="1")
        for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "MEE_SMTP_FAKE_REMOTE",
                    "PRODUCTION_STATE_DIR", "RUNTIME_BASE_COMPOSE", "RUNTIME_USE_REVIEWED_COMPOSE"):
            env.pop(key, None)
        env.update({key: fixture.paths["original-base"] if value == "HISTORICAL" else value
                    for key, value in (overrides or {}).items()})
        # Parent fixture releases its lock; the actual coordinator must acquire it.
        helper.fcntl.flock(9, helper.fcntl.LOCK_UN)
        fallback_before = fixture.saved_identity(fixture.fallback)
        helper_argv = [
            "bash", str(stage / "deploy-test-vps-provider-release.sh"),
            "--root", str(fixture.app), "--base-compose", fixture.paths["reviewed-base"],
            "--image", IMAGE, "--revision", helper.FORWARD_TARGET["source"],
            "--version", "1.6.0", "--run-key", SUCCESSOR, "--mode", "deploy",
            "--failure-policy", "manual-stop", "--pending-locationiq-off",
            "--reconcile-failed-40368479855-forward", "--public-url", public_url,
        ]
        if workflow_route:
            workflow = (SCRIPTS.parent / ".github/workflows/deploy-test-vps.yml").read_text()
            deploy = workflow.split(
                "      - name: Deploy selected release successfully\n", 1
            )[1].split("      - name:", 1)[0]
            body = deploy.split("        run: |\n", 1)[1]
            body = "\n".join(line[10:] for line in body.splitlines())
            body = body.split(
                'grep -Fq "deployment=completed image_id=$TARGET_IMAGE_ID"', 1
            )[0]
            original_run = subprocess.run

            def route_workflow(argv, *args, **kwargs):
                if (isinstance(argv, list) and len(argv) > 1 and argv[0] == "bash"
                        and str(argv[1]).endswith("/deploy-test-vps-provider-release.sh")):
                    values = {argv[index]: argv[index + 1] for index in range(2, 16, 2)}
                    routed_env = dict(kwargs["env"])
                    ssh = Path(routed_env["FORWARD_FIXTURE"]) / "bin/ssh"
                    Fixture.write(ssh, b"""#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
a=sys.argv[1:]
assert a[:3] == ["-F", "OFFLINE_ONLY", "test-vps"]
pathlib.Path(os.environ["FORWARD_FIXTURE"],"actual-ssh-argv.json").write_text(json.dumps(a))
status = subprocess.call(["/usr/bin/bash"]+a[3:])
pathlib.Path(os.environ["FORWARD_FIXTURE"],"helper-exit.json").write_text(json.dumps(status))
sys.exit(status)
""", 0o755)
                    routed_env.update(
                        SSH_CONFIG="OFFLINE_ONLY",
                        REMOTE_TOOLING=str(Path(argv[1]).parent.parent),
                        PATH_ON_HOST=values["--root"],
                        IMAGE="ghcr.io/nickolaymamonov/meet-backend-v3",
                        DIGEST=helper.FORWARD_TARGET["indexDigest"],
                        SOURCE_SHA=helper.FORWARD_TARGET["source"],
                        VERSION="1.6.0",
                        GITHUB_RUN_ID=SUCCESSOR.split("-", 1)[0],
                        GITHUB_RUN_ATTEMPT="1",
                        FAILURE_POLICY="manual-stop",
                        PUBLIC_URL=public_url,
                        APPLY_PENDING_LOCATIONIQ_OFF="true",
                        RECONCILE_FAILED_40368479855_FORWARD="true",
                        RUNNER_TEMP=str(fixture.root),
                    )
                    kwargs["env"] = routed_env
                    result = original_run(["bash", "-c", body], *args, **kwargs)
                    routed = json.loads(
                        (fixture.root / "actual-ssh-argv.json").read_text())
                    expected = [
                        str(argv[1]), "--root", values["--root"],
                        "--base-compose", values["--base-compose"],
                        "--image", IMAGE, "--revision", helper.FORWARD_TARGET["source"],
                        "--version", "1.6.0", "--run-key", SUCCESSOR,
                        "--failure-policy", "manual-stop", "--public-url",
                        public_url, "--pending-locationiq-off",
                        "--reconcile-failed-40368479855-forward", "--mode", "deploy",
                    ]
                    self.assertEqual(routed[3:], expected)
                    return result
                return original_run(argv, *args, **kwargs)

            with mock.patch.object(subprocess, "run", side_effect=route_workflow):
                result = subprocess.run(helper_argv, env=env, capture_output=True, timeout=90)
        else:
            result = subprocess.run(helper_argv, env=env, capture_output=True, timeout=90)
        self.assertEqual(fixture.saved_identity(fixture.fallback), fallback_before)
        output = result.stdout + result.stderr
        for secret in (KEY.encode(), b"fictional@example.invalid",
                       hashlib.sha256(KEY.encode()).hexdigest().encode()):
            self.assertNotIn(secret, output)
        trace = [json.loads(line) for line in (fixture.root / "trace").read_text().splitlines()
                 ] if (fixture.root / "trace").exists() else []
        return fixture, result, trace

    def assert_private_consumers(self, fixture):
        observations = [json.loads(line) for line in
                        (fixture.root / "consumer-trace").read_text().splitlines()]
        self.assertTrue(any(item["operation"] == "up" for item in observations))
        expected = {
            fixture.paths["active-compose"]: fixture.original_files["config.base-compose.yml"],
            fixture.paths["active-runtime"]: fixture.original_files["target-runtime.override.yml"],
        }
        for observation in observations:
            self.assertEqual({item["path"] for item in observation["inputs"]}, set(expected))
            for item in observation["inputs"]:
                self.assertEqual((item["uid"], item["gid"], item["mode"], item["nlink"]),
                                 (0, 0, 0o600, 1))
                self.assertEqual(base64.b64decode(item["bytes"]), expected[item["path"]])

    def test_historical_coordinator_consumes_only_authenticated_private_copies(self):
        for overrides in ({}, {"PRODUCTION_BASE_COMPOSE": "HISTORICAL",
                               "PRODUCTION_USE_REVIEWED_COMPOSE": "true",
                               "PRODUCTION_ROOT": "/unexpected",
                               "COMPOSE_FILE": "HISTORICAL"}):
            with self.subTest(overrides=overrides):
                fixture, result, _ = self.run_shell(historical=True, overrides=overrides)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assert_private_consumers(fixture)

    def test_owner_write_after_validation_never_enters_compose_or_acceptance(self):
        fixture, result, trace = self.run_shell(
            historical=True, failure="owner-write-after-validation")
        self.assertNotEqual(result.returncode, 0)
        self.assert_private_consumers(fixture)
        self.assertTrue(Path(fixture.paths["original-base"]).read_bytes().startswith(b"X"))
        self.assertEqual(len([entry for entry in trace if "up" in entry["argv"]]), 1)
        self.assertTrue(fixture.origin.exists())
        self.assertFalse(fixture.archive.exists())
        self.assertFalse((fixture.successor / "forward-acceptance.json").exists())
        self.assertFalse((fixture.successor / "terminal.json").exists())

    def test_historical_runtime_selection_overrides_block_before_mutation(self):
        for overrides in (
            {"RUNTIME_BASE_COMPOSE": "HISTORICAL"},
            {"RUNTIME_USE_REVIEWED_COMPOSE": "true"},
            {"PRODUCTION_STATE_DIR": "HISTORICAL"},
        ):
            with self.subTest(overrides=overrides):
                fixture, result, trace = self.run_shell(historical=True, overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.unchanged(fixture)
                self.assertFalse([entry for entry in trace if any(
                    arg in ("up", "stop", "start", "restart") for arg in entry["argv"])])
                self.assertFalse((fixture.root / "consumer-trace").exists())

    def test_real_coordinator_success_all_dispositions(self):
        for disposition in ("created", "reused", "none"):
            with self.subTest(disposition=disposition):
                fixture, result, trace = self.run_shell(disposition)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                self.assertIn(b"reconciliation=completed", result.stdout)
                self.assertEqual(sum(line.startswith(b'{"schemaVersion":1,')
                                     for line in result.stdout.splitlines()), 1)
                self.assertFalse(fixture.pointer.exists())
                self.assertTrue(fixture.archive.exists())
                writers = [entry for entry in trace if "up" in entry["argv"]]
                self.assertEqual(len(writers), 1)
                self.assertTrue(all(
                    entry["host"] == "unix:///var/run/docker.sock" and not entry["context"]
                    for entry in trace if entry["argv"][0] != "context"))
                self.assertFalse([entry for entry in trace if entry["argv"][0] == "stop"])
                self.assertEqual(Path(fixture.paths["production-env"]).read_bytes(), fixture.target_env)

    def test_unexpected_endpoint_and_wrapper_overrides_have_zero_writes(self):
        for failure, overrides in (
            ("endpoint", {}), ("", {"DOCKER_HOST": "tcp://unexpected:2375"}),
            ("", {"DOCKER_CONTEXT": "unexpected"}),
            ("", {"RUNTIME_BASE_COMPOSE": "/unexpected.yml"}),
            ("", {"RUNTIME_USE_REVIEWED_COMPOSE": "true"}),
            ("", {"MEE_SMTP_FAKE_REMOTE": "true"}),
            ("", {"PRODUCTION_STATE_DIR": "/unexpected"}),
            ("postgres", {}), ("platform", {}),
        ):
            with self.subTest(failure=failure, overrides=overrides):
                fixture, result, trace = self.run_shell(failure=failure, overrides=overrides)
                self.assertNotEqual(result.returncode, 0)
                self.unchanged(fixture)
                self.assertFalse([entry for entry in trace if
                                  any(arg in ("up", "stop", "start", "restart") for arg in entry["argv"])])

    def test_post_start_failure_stops_only_new_identity_without_replay(self):
        for failure in ("recreate", "candidate-key", "public", "stop", "signal"):
            with self.subTest(failure=failure):
                fixture, result, trace = self.run_shell(failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
                stops = [entry for entry in trace if entry["argv"][0] == "stop"]
                self.assertEqual(len(stops), 1, result.stderr.decode())
                self.assertEqual(stops[0]["argv"], ["stop", NEW])
                self.assertIn(b"backend_stop=failed" if failure == "stop" else
                              b"backend_stop=completed", result.stderr)
                self.assertTrue(stops[0]["explicit"])
                self.assertTrue(fixture.origin.exists())
                self.assertFalse((fixture.successor / "terminal.json").exists())
                self.assertEqual(Path(fixture.paths["production-env"]).read_bytes(), fixture.target_env)

    @mock.patch(__name__ + ".SUCCESSOR", "41190844821-1")
    def test_forward_recovery_phase_markers_are_safe_and_ordered(self):
        def golden(failure=""):
            return self.run_shell("reused", failure=failure, historical=True,
                                  workflow_route=True)

        def assert_phase(result, phase):
            self.assertEqual(result.returncode, 1, result.stderr.decode())
            self.assertEqual(
                [line for line in result.stderr.splitlines()
                 if line.startswith(b"recovery_failure_phase=")],
                [f"recovery_failure_phase={phase}".encode()])

        fixture, result, _ = golden()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertNotIn(b"recovery_failure_phase=", result.stderr)
        boundaries = [
            b"recovery_boundary=adoption-accepted",
            b"recovery_boundary=revalidation-accepted",
            b"recovery_boundary=service-mutation-begin",
        ]
        positions = [result.stderr.find(marker) for marker in boundaries]
        self.assertTrue(all(position >= 0 for position in positions), result.stderr.decode())
        self.assertEqual(positions, sorted(positions))

        # A compose-up failure is an ordinary command failure after the explicit
        # mutation boundary. The EXIT handler must preserve its status and
        # perform the existing identity-checked manual stop.
        fixture, result, trace = golden("recreate")
        assert_phase(result, "service-mutation")
        self.assertIn(b"backend_stop=completed", result.stderr)
        stops = [entry for entry in trace if entry["argv"][0] == "stop"]
        self.assertEqual([entry["argv"] for entry in stops], [["stop", NEW]])
        self.assertTrue(fixture.origin.exists())
        self.assertFalse((fixture.successor / "terminal.json").exists())
        self.assertNotIn(str(fixture.root).encode(), result.stdout + result.stderr)
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)

        for failure, phase, adopted, mutated in (
            ("pin", "docker-pin", False, False),
            ("predecessor", "predecessor", False, False),
            ("rendered-witness", "rendered-witness", False, False),
            ("native-adoption", "native-adoption", False, False),
            ("revalidation", "revalidation", True, False),
            ("forward-complete", "forward-complete", True, True),
        ):
            with self.subTest(failure=failure):
                fixture, result, trace = golden(failure)
                assert_phase(result, phase)
                self.assertIn(b"RECOVERY_REQUIRED", result.stderr.splitlines())
                writes = [entry for entry in trace if any(
                    arg in ("up", "stop", "start", "restart")
                    for arg in entry["argv"])]
                if mutated:
                    self.assertTrue(any("up" in entry["argv"] for entry in writes))
                    self.assertEqual([entry["argv"] for entry in writes
                                      if entry["argv"][0] == "stop"], [["stop", NEW]])
                else:
                    self.assertFalse([entry for entry in writes
                                      if entry["argv"][0] != "up"])
                    self.assertFalse([entry for entry in writes
                                      if entry["argv"][0] == "up"])
                if adopted:
                    self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
                else:
                    self.assertEqual(fixture.marker()["runKey"],
                                     helper.FORWARD_ORIGIN_KEY)
                self.assertNotIn(str(fixture.root).encode(),
                                 result.stdout + result.stderr)
                self.assertNotIn(KEY.encode(), result.stdout + result.stderr)

        # jq is an ordinary shell command here (no `|| fail` wrapper). Injecting
        # its failure proves set -e reaches the replacement EXIT handler after
        # native adoption but before any revalidation or service mutation.
        fixture, result, trace = golden("adoption-jq")
        assert_phase(result, "adoption-accepted")
        self.assertEqual(json.loads((fixture.root / "helper-exit.json").read_text()), 42)
        self.assertEqual(fixture.marker()["runKey"], SUCCESSOR)
        self.assertFalse([entry for entry in trace if any(
            arg in ("up", "stop", "start", "restart") for arg in entry["argv"])])
        self.assertTrue(fixture.origin.exists())
        self.assertFalse((fixture.successor / "terminal.json").exists())
        self.assertNotIn(str(fixture.root).encode(), result.stdout + result.stderr)
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)

        # A failed post-mutation proof is reported at the proof boundary and
        # retains the same safe-stop behavior as the existing public probe path.
        fixture, result, trace = golden("public")
        assert_phase(result, "backend-proof")
        self.assertIn(b"backend_stop=completed", result.stderr)
        stops = [entry for entry in trace if entry["argv"][0] == "stop"]
        self.assertEqual([entry["argv"] for entry in stops], [["stop", NEW]])
        self.assertNotIn(str(fixture.root).encode(), result.stdout + result.stderr)
        self.assertNotIn(KEY.encode(), result.stdout + result.stderr)


def resource_worker(limit):
    import runpy
    producer = runpy.run_path(str(SCRIPTS / "test-test-vps-state-admission.py"))
    fixture = Fixture()
    old = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        for number in range(1364):
            producer["generation"](fixture.states, f"g{number}")
        for number in range(2):
            producer["beta"](fixture.states, recovery_id=f"fixture-{number:03d}")
        saved = {name: producer["snapshot"](fixture.states / name)
                 for name in (".smtp-last-good-generations",
                              "beta-recovery-fixture-000", "beta-recovery-fixture-001")}
        baseline = len(os.listdir("/proc/self/fd"))
        resource.setrlimit(resource.RLIMIT_NOFILE, (limit, old[1]))
        fixture.admit()
        helper._forward_revalidate(str(fixture.states), SUCCESSOR, encode([fixture.backend]))
        fixture.phase()
        fixture.complete()
        for name, value in saved.items():
            assert producer["snapshot"](fixture.states / name) == value
        assert len(os.listdir("/proc/self/fd")) == baseline
        print(f"PRODUCTION_LOW_RLIMIT_PASS limit={limit} descendants=4096 cleanup_delta=0", flush=True)
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, old)
        fixture.close()


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] == "--resource-worker":
    resource_worker(int(sys.argv[2]))
elif __name__ == "__main__":
    unittest.main()
