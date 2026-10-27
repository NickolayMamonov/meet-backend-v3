#!/usr/bin/env python3
"""Offline Linux/root producer-admission fixtures; fictional records only."""
import sys
sys.dont_write_bytecode = True

import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import tempfile
import unittest
import shutil
from unittest import mock

import test_vps_state_admission as admission


def journal(recovery_id="fixture-123", phase="incident_resolved"):
    return {
        "schema": "meet-backend/beta-recovery-journal/v1",
        "recoveryId": recovery_id, "state": "terminal", "phase": phase,
        "capturedContainerId": "a" * 64, "capturedImageId": "sha256:" + "b" * 64,
        "capturedRuntimeDigest": "c" * 64, "currentRuntimeHealthy": True,
        "capturedContainerSafe": True, "ownedPaths": admission.OWNED_PATHS,
    }


def manifest(name, env):
    return {
        "schema": "2", "generation": name,
        "env_sha256": hashlib.sha256(env).hexdigest(),
        "non_email_config_sha256": admission.non_email_digest(env),
        "non_email_runtime_fingerprint": "a" * 64, "runtime_fingerprint": "b" * 64,
        "release_image": "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "c" * 64,
        "release_version": "1.6.0", "release_revision": "d" * 40,
    }


def manifest_bytes(value):
    return "".join(f"{key}={item}\n" for key, item in value.items()).encode()


def write(path, data):
    path.write_bytes(data)
    path.chmod(0o600)


def beta(root, phase="incident_resolved", recovery_id="fixture-123"):
    directory = root / ("beta-recovery-" + recovery_id)
    directory.mkdir(mode=0o700)
    write(directory / "journal.json", json.dumps(journal(recovery_id, phase)).encode())
    write(directory / "incident.json", json.dumps({
        "schema": "meet-backend/beta-recovery-incident/v1",
        "recoveryId": recovery_id, "status": phase, "sanitized": True}).encode())
    return directory


def generation(root, name="fixture-apply-ABC123", env=b"OTHER=fictional\n"):
    container = root / admission.GENERATIONS
    container.mkdir(mode=0o700, exist_ok=True)
    directory = container / name
    directory.mkdir(mode=0o700)
    write(directory / "env", env)
    write(directory / "manifest", manifest_bytes(manifest(name, env)))
    return directory


def snapshot(root):
    result = {}
    for path in [root, *root.rglob("*")]:
        info = path.lstat()
        result[str(path.relative_to(root))] = (
            admission.identity(info), tuple(os.listxattr(path, follow_symlinks=False)),
            path.read_bytes() if stat.S_ISREG(info.st_mode) else None)
    return result


class SchemaTests(unittest.TestCase):
    def test_pure_producer_validator_parity_without_entrypoints(self):
        scripts = Path(__file__).resolve().parent
        def function(source, name):
            text = source.read_text()
            start = text.index(name + "() {") if name + "() {" in text else text.index(name + "(){")
            end = text.index("\n}", start) + 2
            return text[start:end]

        beta_source = scripts / "run-beta-recovery-capture.sh"
        beta_functions = "\n".join(function(beta_source, name)
                                   for name in ("validate_journal", "validate_incident"))
        smtp_source = scripts / "configure-test-vps-yandex-smtp.sh"
        smtp_functions = "\n".join(function(smtp_source, name) for name in (
            "sha256_file", "non_email_config_digest_file", "validate_generation"))
        with tempfile.TemporaryDirectory(dir="/root") as temporary:
            root = Path(temporary)
            path = root / "journal.json"
            for phase in ("incident_resolved", "superseded", "pre_stop", "invalid"):
                value = journal(phase=phase)
                if phase == "pre_stop":
                    value["state"] = "nonterminal"
                raw = json.dumps(value).encode()
                write(path, raw)
                command = ('owned=' + "'" + json.dumps(admission.OWNED_PATHS) + "'\n"
                           + 'script_dir=$2\n' + beta_functions + '\nvalidate_journal "$1"')
                result = subprocess.run(["bash", "-c", command, "parity", str(path),
                                         str(scripts)], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
                try:
                    admission.beta_journal(raw)
                    expected = 0
                except admission.Rejected:
                    expected = 1
                self.assertEqual(result.returncode == 0, expected == 0, result.stderr.decode())
            for length in (128, 129, 130, 255):
                name = "a" * length
                directory = generation(root, name)
                for corrupt in (False, True):
                    value = manifest(name, (directory / "env").read_bytes())
                    if corrupt:
                        value["release_version"] = "01.2.3"
                    raw = manifest_bytes(value)
                    write(directory / "manifest", raw)
                    command = ('generations=$1; script_dir=$3; declare -A generation_manifest=()\n'
                               + smtp_functions + '\nvalidate_generation "$2"')
                    result = subprocess.run(["bash", "-c", command, "parity",
                                             str(root / admission.GENERATIONS), name,
                                             str(scripts)], stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE)
                    self.assertEqual(result.returncode == 0, not corrupt,
                                     result.stderr.decode())

    def test_awk_digest_exact_byte_parity(self):
        samples = [b"", b"\n", b"A=x", b"A=x\n", b"A=x\n\n",
                   b"A=x\r\n", b"A=x\vB=y", b"\xff\x00=x\n",
                   b"APP_EMAIL_FROM=x", b" APP_EMAIL_FROM=x\n",
                   b"APP_EMAIL_FROM_NAME=x\r\nA=y\r", b"APP_EMAIL_FROMX=x\n"]
        samples += [key + b"=fictional\nA=z\n" for key in admission.EMAIL_KEYS]
        awk = b"/^(" + b"|".join(admission.EMAIL_KEYS) + b")=/ {next} {print}"
        for data in samples:
            with self.subTest(data=data):
                expected = subprocess.run(["awk", awk.decode()], input=data,
                                          stdout=subprocess.PIPE, check=True).stdout
                self.assertEqual(admission.non_email_digest(data),
                                 hashlib.sha256(expected).hexdigest())

    def test_generation_name_limits_before_lookup(self):
        for length in (1, 128, 129, 130, 255):
            admission.generation_name("a" * length)
        for value in ("", "a" * 256, ".", "..", "a/b", "a\n", "é", "-x", "a\x00"):
            with self.subTest(value=value), self.assertRaises(admission.Rejected):
                admission.generation_name(value)
        with mock.patch.object(admission.os, "stat", side_effect=AssertionError("lookup")):
            with self.assertRaises(admission.Rejected):
                admission.generation_record("a" * 256, b"", b"")

    def test_generation_schema_each_field_and_duplicates(self):
        name, env = "fixture", b"A=b\n"
        valid = manifest(name, env)
        admission.generation_record(name, env, manifest_bytes(valid))
        for key in valid:
            for mutation in ("missing", "invalid", "duplicate"):
                value = copy.deepcopy(valid)
                if mutation == "missing":
                    del value[key]
                else:
                    value[key] = "invalid"
                raw = manifest_bytes(value)
                if mutation == "duplicate":
                    raw = manifest_bytes(valid) + manifest_bytes({key: valid[key]})
                with self.subTest(key=key, mutation=mutation), self.assertRaises(admission.Rejected):
                    admission.generation_record(name, env, raw)
        for raw in (manifest_bytes(valid) + b"unknown=x\n",
                    manifest_bytes(valid) + b"\n",
                    manifest_bytes(valid).replace(b"\n", b"\r\n")):
            with self.assertRaises(admission.Rejected):
                admission.generation_record(name, env, raw)
        admission.generation_record(name, env, manifest_bytes(valid).rstrip(b"\n"))
        for length in (128, 129, 130, 255):
            name = "a" * length
            valid = manifest(name, env)
            for key in ("generation", "env_sha256", "non_email_config_sha256", "schema"):
                value = dict(valid, **{key: "invalid"})
                with self.subTest(length=length, key=key), self.assertRaises(admission.Rejected):
                    admission.generation_record(name, env, manifest_bytes(value))
            with self.assertRaises(admission.Rejected):
                admission.selector_value(name.encode() + b"\n\n", {name})

    def test_beta_schema_enum_types_and_duplicate_keys(self):
        valid = journal()
        admission.beta_journal(json.dumps(valid).encode())
        for key in valid:
            for invalid in (None, [], {}, False, 1, "invalid"):
                value = dict(valid, **{key: invalid})
                with self.subTest(key=key, invalid=invalid), self.assertRaises(admission.Rejected):
                    admission.beta_journal(json.dumps(value).encode())
        with self.assertRaises(admission.Rejected):
            admission.beta_journal(b'{"schema":1,"schema":1}')


class PackagingTests(unittest.TestCase):
    def test_isolated_exact_local_provider_import_missing_and_tampered_dependency(self):
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            helper = stage / "test-vps-provider-credential.py"
            module = stage / "test_vps_state_admission.py"
            shutil.copyfile(scripts / helper.name, helper)
            shutil.copyfile(scripts / module.name, module)
            expected = hashlib.sha256(module.read_bytes()).hexdigest()
            write(stage / "SHA256SUMS", f"{expected}  {module.name}\n".encode())
            command = (
                "import importlib.util,pathlib;"
                "s=importlib.util.spec_from_file_location('fixture_provider',"
                "'test-vps-provider-credential.py');"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                "a=m._forward_state_module();"
                "assert pathlib.Path(a.__file__).parent==pathlib.Path.cwd();"
                "a.generation_name('a'*255)")
            environment = dict(os.environ, PYTHONPATH=str(scripts),
                               PYTHONDONTWRITEBYTECODE="0")
            for _ in range(2):
                result = subprocess.run([sys.executable, "-B", "-c", command], cwd=stage,
                                        env=environment, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertFalse((stage / "__pycache__").exists())
            subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=stage,
                           capture_output=True, check=True)
            module.write_bytes(module.read_bytes() + b"\n# tampered fixture\n")
            self.assertNotEqual(subprocess.run(["sha256sum", "-c", "SHA256SUMS"],
                                               cwd=stage, capture_output=True).returncode, 0)
            module.unlink()
            result = subprocess.run([sys.executable, "-B", "-c", command], cwd=stage,
                                    env=environment, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(b"/src/scripts/test_vps_state_admission", result.stderr)

    def test_staged_beta_and_smtp_pure_cli_checksum_failure_and_no_caches(self):
        scripts = Path(__file__).resolve().parent
        for consumer in ("run-beta-recovery-capture.sh", "configure-test-vps-yandex-smtp.sh"):
            with self.subTest(consumer=consumer), tempfile.TemporaryDirectory() as temporary:
                stage = Path(temporary)
                module = stage / "test_vps_state_admission.py"
                shutil.copyfile(scripts / module.name, module)
                shutil.copyfile(scripts / consumer, stage / consumer)
                expected = hashlib.sha256(module.read_bytes()).hexdigest()
                write(stage / "SHA256SUMS", f"{expected}  {module.name}\n".encode())
                name, env = "fixture", b"A=b\n"
                write(stage / "manifest", manifest_bytes(manifest(name, env)))
                if consumer.startswith("run-beta"):
                    args = ["beta-journal", "-"]
                    data = json.dumps(journal()).encode()
                else:
                    args = ["smtp-manifest", name, "manifest",
                            hashlib.sha256(env).hexdigest(), admission.non_email_digest(env)]
                    data = b""
                command = [sys.executable, "-B", str(module), *args]
                for _ in range(2):
                    result = subprocess.run(command, input=data, cwd=stage, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(result.stdout, b"")
                self.assertFalse((stage / "__pycache__").exists())
                module.write_bytes(module.read_bytes() + b"\n# fictional tamper\n")
                self.assertNotEqual(subprocess.run(["sha256sum", "-c", "SHA256SUMS"],
                                                   cwd=stage, capture_output=True).returncode, 0)
                module.unlink()
                result = subprocess.run(command, input=data, cwd=stage, capture_output=True)
                self.assertNotEqual(result.returncode, 0)


@unittest.skipUnless(sys.platform == "linux" and os.geteuid() == 0, "Linux/root required")
class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.root.chmod(0o700)
        self.fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)

    def tearDown(self):
        os.close(self.fd)
        self.tmp.cleanup()

    def inventory(self, excluded=frozenset()):
        return admission.Inventory(self.fd, set(excluded))

    def reject_unchanged(self):
        before = snapshot(self.root)
        with self.assertRaises((admission.Rejected, OSError)):
            with self.inventory():
                self.fail("accepted")
        self.assertEqual(snapshot(self.root), before)

    def test_empty_and_complete_generations_limits_selector(self):
        for length in (128, 129, 130, 255):
            name = "a" * length
            directory = generation(self.root, name)
            write(self.root / admission.SELECTOR, name.encode() + b"\n")
            before = snapshot(self.root)
            with self.inventory() as inventory:
                self.assertEqual(inventory.results[admission.SELECTOR].disposition, "preserve")
                inventory.recheck()
            self.assertEqual(snapshot(self.root), before)
            # Keep historical generations when changing selection.
            self.assertTrue(directory.exists())
        with self.inventory() as inventory:
            self.assertEqual(len(inventory.witnesses), 14)

    def test_beta_terminal_both_phases_optional_private(self):
        for phase in ("incident_resolved", "superseded"):
            directory = beta(self.root, phase, phase)
            (directory / "private").mkdir(mode=0o700)
        before = snapshot(self.root)
        with self.inventory() as inventory:
            inventory.recheck()
            self.assertTrue(all(value.category == "beta-terminal"
                                for value in inventory.results.values()))
        self.assertEqual(snapshot(self.root), before)

    def test_nonterminal_and_residual_beta(self):
        directory = beta(self.root)
        original = journal()
        for phase in ("pre_stop", "snapshot_complete", "runtime_verified"):
            value = dict(original, state="nonterminal", phase=phase)
            write(directory / "journal.json", json.dumps(value).encode())
            self.reject_unchanged()
        write(directory / "journal.json", json.dumps(original).encode())
        for name in ("staging", "journal.json.tmp", "capture-runtime.json"):
            path = directory / name
            write(path, b"fictional")
            self.reject_unchanged()
            path.unlink()
        write(directory / "incident.json", b"{}")
        self.reject_unchanged()

    def test_beta_identity_and_empty_private_trust_fail_closed(self):
        directory = beta(self.root)
        valid = journal()
        for key, value in (("recoveryId", "different-123"),
                           ("ownedPaths", ["private/forged"]),
                           ("phase", "superseded")):
            write(directory / "journal.json", json.dumps(dict(valid, **{key: value})).encode())
            self.reject_unchanged()
        write(directory / "journal.json", json.dumps(valid).encode())
        private = directory / "private"
        private.mkdir(mode=0o700)
        write(private / "payload", b"residual")
        self.reject_unchanged()
        (private / "payload").unlink()
        private.chmod(0o755)
        self.reject_unchanged()
        private.chmod(0o700)
        acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", tag, perm, uid)
            for tag, perm, uid in ((1, 7, 0xffffffff), (2, 4, 1001),
                                   (4, 0, 0xffffffff), (16, 0, 0xffffffff),
                                   (32, 0, 0xffffffff)))
        os.setxattr(private, "system.posix_acl_default", acl)
        self.reject_unchanged()

    def test_transaction_pointer_any_shape_and_orphan_terminal(self):
        directory = self.root / admission.TRANSACTIONS
        directory.mkdir(mode=0o700)
        with self.inventory():
            pass
        for phase in ("COMMITTED", "RECOVERED", "SNAPSHOTTED", "VERIFIED"):
            pointer = self.root / admission.POINTER
            write(pointer, phase.encode())
            self.reject_unchanged()
            pointer.unlink()
            orphan = directory / phase
            orphan.mkdir(mode=0o700)
            write(orphan / "journal", phase.encode())
            self.reject_unchanged()
            (orphan / "journal").unlink()
            orphan.rmdir()

    def test_selector_bad_bindings_and_unselected_bad_generation(self):
        directory = generation(self.root)
        for value in (b"missing\n", b"fixture-apply-ABC123", b"fixture-apply-ABC123\n\n",
                      b"../fixture\n", b"", b"\xff\n"):
            write(self.root / admission.SELECTOR, value)
            self.reject_unchanged()
        write(self.root / admission.SELECTOR, b"fixture-apply-ABC123\n")
        bad = generation(self.root, "unselected")
        write(bad / "manifest", b"invalid")
        self.reject_unchanged()
        self.assertTrue(directory.exists())

    def test_unknown_and_old_probe_sidecars_preserved(self):
        for name in ("manual", ".runtime.ABC123.body", ".pre-capture.X.headers",
                     ".smtp-last-good.current.tmp", ".smtp-sync-probe.ABC123"):
            path = self.root / name
            write(path, b"fictional")
            self.reject_unchanged()
            path.unlink()

    def test_real_trust_hostility(self):
        directory = generation(self.root)
        path = directory / "env"
        original = path.read_bytes()
        for uid, gid, mode in ((1001, 0, 0o600), (0, 1001, 0o600),
                               (0, 0, 0o644), (0, 0, 0o660)):
            os.chown(path, uid, gid)
            path.chmod(mode)
            self.reject_unchanged()
        os.chown(path, 0, 0)
        path.chmod(0o600)
        with tempfile.TemporaryDirectory(dir="/root") as outside:
            alias = Path(outside) / "alias"
            os.link(path, alias)
            self.reject_unchanged()
            alias.unlink()
        path.unlink()
        path.symlink_to("/dev/null")
        self.reject_unchanged()
        path.unlink()
        os.mkfifo(path, 0o600)
        self.reject_unchanged()
        path.unlink()
        sock = socket.socket(socket.AF_UNIX)
        try:
            sock.bind(str(path))
            path.chmod(0o600)
            self.reject_unchanged()
        finally:
            sock.close()
        path.unlink()
        os.mknod(path, stat.S_IFCHR | 0o600, os.makedev(1, 3))
        self.reject_unchanged()
        path.unlink()
        write(path, original)
        for target in (path, directory, directory.parent):
            target.chmod(0o777)
            self.reject_unchanged()
            target.chmod(0o600 if target == path else 0o700)
        # Named UID ACL with a zero mask is still an extended ACL, not plain mode.
        acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", tag, perm, uid)
            for tag, perm, uid in ((1, 6, 0xffffffff), (2, 4, 1001),
                                   (4, 0, 0xffffffff), (16, 0, 0xffffffff),
                                   (32, 0, 0xffffffff)))
        os.setxattr(path, "system.posix_acl_access", acl)
        self.reject_unchanged()
        os.removexattr(path, "system.posix_acl_access")
        with mock.patch.object(admission.os, "getxattr", side_effect=OSError(95, "unsupported")):
            with self.assertRaises(admission.Rejected):
                self.inventory()

    def test_rechecks_foreign_bytes_names_binding_and_own_exact_deltas(self):
        directory = generation(self.root)
        with self.inventory() as inventory:
            own = self.root / "exact-own-staging"
            own.mkdir(mode=0o700)
            inventory.recheck(added=frozenset({own.name}))
            with self.assertRaises(admission.Rejected):
                inventory.recheck()
            own.rmdir()
            write(directory / "env", b"changed")
            with self.assertRaises(admission.Rejected):
                inventory.recheck()

    def test_directory_replacement_and_descendant_addition(self):
        directory = generation(self.root)
        with self.inventory() as inventory:
            moved = directory.with_name("moved")
            directory.rename(moved)
            directory.mkdir(mode=0o700)
            with self.assertRaises(admission.Rejected):
                inventory.recheck()

    def test_pinned_ancestor_swap_and_mode_drift(self):
        generation(self.root)
        with self.inventory() as inventory:
            self.root.chmod(0o777)
            with self.assertRaises(admission.Rejected):
                inventory.recheck()
            self.root.chmod(0o700)
        original = self.root / "parent"
        original.mkdir(mode=0o700)
        nested = original / "states"
        nested.mkdir(mode=0o700)
        fd = os.open(nested, os.O_RDONLY | os.O_DIRECTORY)
        try:
            with admission.Inventory(fd, set(), root_path=str(nested)) as inventory:
                original.rename(self.root / "old-parent")
                original.mkdir(mode=0o700)
                (original / "states").mkdir(mode=0o700)
                with self.assertRaises(admission.Rejected):
                    inventory.recheck()
        finally:
            os.close(fd)

    def test_mount_identity_and_short_read_fail_closed(self):
        generation(self.root)
        actual_mount = admission.Inventory._mount
        calls = 0
        def mount(fd):
            nonlocal calls
            calls += 1
            return "different" if calls == 3 else actual_mount(fd)
        with mock.patch.object(admission.Inventory, "_mount", side_effect=mount):
            with self.assertRaises(admission.Rejected):
                self.inventory()
        # Real nonblocking FD plus injected early EOF; never accept a prefix hash.
        actual_pread = os.pread
        with mock.patch.object(admission.os, "pread", side_effect=lambda fd, count, offset:
                               b"" if offset else actual_pread(fd, 1, offset)):
            with self.assertRaises(admission.Rejected):
                self.inventory()

    def test_enumeration_error_and_depth_guard(self):
        generation(self.root)
        with mock.patch.object(admission.os, "scandir", side_effect=OSError("incomplete")):
            with self.assertRaises(OSError):
                self.inventory()
        empty = self.root / "exact-own"
        empty.mkdir(mode=0o700)
        with self.inventory({empty.name}) as inventory:
            inventory._directory(inventory.root, empty.name, admission.MAX_DEPTH)
            with self.assertRaises(admission.Rejected):
                inventory._directory(inventory.root, empty.name, admission.MAX_DEPTH + 1)

    def test_actual_root_entry_limit_and_complete_enumeration(self):
        for number in range(admission.ROOT_ENTRIES):
            write(self.root / str(number), b"")
        self.assertEqual(len(admission.names(self.fd, admission.ROOT_ENTRIES)), 4096)
        write(self.root / "one-over", b"")
        with self.assertRaises(admission.Rejected):
            admission.names(self.fd, admission.ROOT_ENTRIES)

    def test_actual_env_budget_exact_and_one_over(self):
        env = b"A" * admission.ENV_BYTES
        directory = generation(self.root, env=env)
        with self.inventory():
            pass
        write(directory / "env", env + b"A")
        self.reject_unchanged()

    def test_actual_record_and_aggregate_byte_limits(self):
        directory = beta(self.root)
        path = directory / "journal.json"
        raw = path.read_bytes()
        write(path, raw + b" " * (admission.RECORD_BYTES - len(raw)))
        with self.inventory():
            pass
        write(path, path.read_bytes() + b" ")
        self.reject_unchanged()
        path.unlink()
        (directory / "incident.json").unlink()
        directory.rmdir()
        record_size = len(manifest_bytes(manifest("a00", b"A")))
        for number in range(16):
            size = admission.ENV_BYTES
            if number == 15:
                size -= 16 * record_size
            generation(self.root, f"a{number:02d}", b"A" * size)
        self.assertEqual(sum(path.stat().st_size for path in self.root.rglob("*")
                             if path.is_file()), admission.TOTAL_BYTES)
        with self.inventory() as inventory:
            inventory.recheck()
        directory = self.root / admission.GENERATIONS / "a15"
        env = (directory / "env").read_bytes() + b"A"
        write(directory / "env", env)
        write(directory / "manifest", manifest_bytes(manifest("a15", env)))
        self.reject_unchanged()

    def test_actual_descendant_limit_and_valid_directory_link_counts(self):
        for number in range(1364):
            generation(self.root, f"g{number}")
        for number in range(2):
            beta(self.root, recovery_id=f"fixture-{number:03d}")
        with self.inventory() as inventory:
            self.assertEqual(inventory.entries, admission.DESCENDANT_ENTRIES)
            self.assertGreater((self.root / admission.GENERATIONS).stat().st_nlink, 1)
        (self.root / "beta-recovery-fixture-000" / "private").mkdir(mode=0o700)
        self.reject_unchanged()

    def test_enumeration_order_independent_and_no_bytecode_writes(self):
        beta(self.root)
        generation(self.root)
        write(self.root / admission.SELECTOR, b"fixture-apply-ABC123\n")
        actual_names = admission.names
        before = snapshot(self.root)
        with mock.patch.object(admission, "names", side_effect=lambda fd, limit:
                               frozenset(reversed(tuple(actual_names(fd, limit))))):
            with self.inventory() as inventory:
                inventory.recheck()
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse(any(self.root.rglob("__pycache__")))

    def test_bounds_exact_and_one_over(self):
        # Exercise policy limits with small injected caps and real enumeration.
        beta(self.root)
        with mock.patch.object(admission, "ROOT_ENTRIES", 1):
            with self.inventory():
                pass
            write(self.root / "unknown", b"")
            self.reject_unchanged()
        (self.root / "unknown").unlink()
        with mock.patch.object(admission, "DESCENDANT_ENTRIES", 2):
            with self.inventory():
                pass
        with mock.patch.object(admission, "DESCENDANT_ENTRIES", 1):
            self.reject_unchanged()
        with mock.patch.object(admission, "MAX_DEPTH", 0):
            self.reject_unchanged()
        record = self.root / "beta-recovery-fixture-123" / "journal.json"
        length = record.stat().st_size
        with mock.patch.object(admission, "RECORD_BYTES", length):
            with self.inventory():
                pass
        with mock.patch.object(admission, "RECORD_BYTES", length - 1):
            self.reject_unchanged()
        total = sum(path.stat().st_size for path in self.root.rglob("*.json"))
        with mock.patch.object(admission, "TOTAL_BYTES", total):
            with self.inventory():
                pass
        with mock.patch.object(admission, "TOTAL_BYTES", total - 1):
            self.reject_unchanged()


if __name__ == "__main__":
    unittest.main()
