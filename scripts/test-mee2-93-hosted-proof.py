#!/usr/bin/env python3
"""Contract fixtures and the native descriptor proof for MEE2-93.

The default invocation is a bounded standard-library unittest suite.  The
privileged ``--linux-runtime`` invocation loads the exact subject helper in
one persistent process and measures descriptor ownership before rescue.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from typing import Any, Callable
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import importlib

proof = importlib.import_module("mee2-93-hosted-proof")
INVENTORY = proof.INVENTORY
SUBJECT_FILES = tuple(proof.SUBJECT_FILES)


def assert_failure(test: unittest.TestCase, action: Callable[[], Any]) -> None:
    with test.assertRaises(proof.ProofFailure):
        action()


def _pid_running(pid: int) -> bool:
    try:
        stat_path = Path(f"/proc/{pid}/stat")
        if stat_path.exists():
            return stat_path.read_text(encoding="ascii").split()[2] != "Z"
        os.kill(pid, 0)
        return True
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return False


def child_grandchild_timeout_fixture() -> None:
    if os.name != "posix" or sys.platform != "linux":
        return
    with tempfile.TemporaryDirectory(prefix="mee2-95-timeout-") as directory:
        pid_file = Path(directory) / "pids"
        child_source = (
            "import os, pathlib, signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "grandchild_pid = os.fork()\n"
            "if grandchild_pid == 0:\n"
            "    time.sleep(60)\n"
            "else:\n"
            f"    pathlib.Path({str(pid_file)!r}).write_text("
            "str(os.getpid()) + ' ' + str(grandchild_pid), encoding='ascii')\n"
            "    time.sleep(60)\n"
        )
        result = proof.bounded_run(
            [sys.executable, "-c", child_source],
            cwd=HERE,
            timeout_seconds=1,
            env={"PATH": os.defpath},
        )
        if not result.timed_out:
            raise AssertionError("child-grandchild fixture did not time out")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if pid_file.exists():
                pids = [int(value) for value in pid_file.read_text().split()]
                if all(not _pid_running(pid) for pid in pids):
                    return
            time.sleep(0.05)
        raise AssertionError("child-grandchild process tree survived timeout")


def orphaned_pipe_timeout_fixture() -> None:
    if os.name != "posix" or sys.platform != "linux":
        return
    with tempfile.TemporaryDirectory(prefix="mee2-95-orphaned-pipe-") as directory:
        pid_file = Path(directory) / "pids"
        child_source = (
            "import os, pathlib, signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "child_pid = os.fork()\n"
            "if child_pid == 0:\n"
            "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "    grandchild_pid = os.fork()\n"
            "    if grandchild_pid == 0:\n"
            "        time.sleep(60)\n"
            "    else:\n"
            f"        pathlib.Path({str(pid_file)!r}).write_text(\n"
            "            str(os.getpid()) + ' ' + str(grandchild_pid), encoding='ascii')\n"
            "        time.sleep(60)\n"
            "else:\n"
            "    time.sleep(0.1)\n"
            "    os._exit(0)\n"
        )
        result = proof.bounded_run(
            [sys.executable, "-c", child_source],
            cwd=HERE,
            timeout_seconds=0.5,
            env={"PATH": os.defpath},
        )
        if result.returncode != 0 or not result.timed_out or result.cleanup_failed:
            raise AssertionError("orphaned pipe was not bounded and cleaned")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if pid_file.exists():
                pids = [int(value) for value in pid_file.read_text().split()]
                if all(not _pid_running(pid) for pid in pids):
                    return
            time.sleep(0.05)
        raise AssertionError("orphaned pipe descendants survived cleanup")


def passing_proof() -> dict[str, Any]:
    value = proof.initial_evidence("a" * 40, "b" * 40)
    value["images"]["predecessor"]["imageId"] = "sha256:" + "a" * 64
    value["images"]["target"]["imageId"] = "sha256:" + "b" * 64
    value["images"]["postgres"]["imageId"] = "sha256:" + "c" * 64
    for suite_name, suite in value["suites"].items():
        suite["status"] = "passed"
        suite["exitCode"] = 0
        for group in suite["cases"]:
            suite["cases"][group] = "passed"
        if suite_name == "filesystem":
            for record in suite["descriptorFailures"].values():
                record["status"] = "passed"
                record["iterations"] = 100
                record["maxFdGrowthBeforeRescue"] = 0
    for key in value["cleanup"]:
        value["cleanup"][key] = "passed"
    value["verdict"] = "pass"
    return value


class HostedProofContractTests(unittest.TestCase):
    def test_complete_pass_fixture(self) -> None:
        proof.validate_proof(passing_proof())

    def test_evidence_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            proof.write_evidence(root, passing_proof())
            proof.validate_evidence_root(str(root))

    def test_wrong_ref(self) -> None:
        value = passing_proof()
        value["images"]["predecessor"]["ref"] = "ghcr.io/example/changed@sha256:" + "a" * 64
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_tree_drift(self) -> None:
        value = passing_proof()
        value["identity"]["subjectSha"] = "a" * 40
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_helper_drift(self) -> None:
        value = passing_proof()
        value["identity"]["subjectFiles"][0]["sha256"] = "a" * 64
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_wrong_digest(self) -> None:
        value = passing_proof()
        value["identity"]["suppliedPlanSha256"] = "a" * 64
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_missing_image(self) -> None:
        value = passing_proof()
        del value["images"]["postgres"]
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_duplicate_image_id(self) -> None:
        value = passing_proof()
        value["images"]["predecessor"]["imageId"] = "sha256:" + "a" * 64
        value["images"]["target"]["imageId"] = "sha256:" + "a" * 64
        with self.assertRaises(proof.ProofFailure):
            proof.validate_proof(value)

    def test_wrong_postgres(self) -> None:
        value = passing_proof()
        value["images"]["postgres"]["ref"] = value["images"]["target"]["ref"]
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_unsafe_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subject = root / "subject"
            tooling = root / "tooling"
            subject.mkdir()
            tooling.mkdir()
            link = root / "link"
            link.symlink_to(subject, target_is_directory=True)
            assert_failure(
                self,
                lambda: proof.validate_roots(
                    str(link), str(tooling), str(root / "private"), str(root / "evidence")
                ),
            )

    def test_sibling_parent_alias_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subject = root / "subject"
            tooling = root / "tooling"
            other = root / "other"
            subject.mkdir()
            tooling.mkdir()
            other.mkdir()
            assert_failure(
                self,
                lambda: proof.validate_roots(
                    str(subject),
                    str(tooling),
                    str(other / ".." / "subject" / "private"),
                    str(root / "evidence"),
                ),
            )

    def test_startup_override(self) -> None:
        previous = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = "forbidden"
        try:
            assert_failure(self, proof.clean_child_env)
        finally:
            if previous is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = previous

    def test_python_optimized(self) -> None:
        self.assertEqual(sys.flags.optimize, 0)

    def test_inventory_missing_group(self) -> None:
        self.assertEqual(
            set(INVENTORY["groups"]["filesystem"]),
            {"publication", "credential_lifecycle", "retention_races",
             "crash_recovery", "helper_contract", "descriptor_stability"},
        )

    def test_missing_or_duplicate_marker(self) -> None:
        self.assertEqual(proof.marker_count(b"marker=one\n", b"marker=two"), 0)
        self.assertEqual(proof.marker_count(b"marker=one\n", b"marker=one"), 1)

    def test_duplicate_required_marker(self) -> None:
        self.assertEqual(
            proof.marker_count(b"required value\nrequired duplicate\n", b"required"),
            2,
        )

    def test_immutable_failure_code_is_allowlisted_progress_only(self) -> None:
        disabled_stages = b"".join(
            (
                f"image_runtime_stage case=disabled stage={stage}\n"
            ).encode("ascii")
            for stage in proof.IMMUTABLE_STAGES
        )
        enabled_stages = b"".join(
            (
                f"image_runtime_stage case=enabled stage={stage}\n"
            ).encode("ascii")
            for stage in proof.IMMUTABLE_STAGES
        )
        disabled = disabled_stages + b"image_runtime case=disabled previous_id=x\n"
        disabled_cleanup = b"image_runtime_cleanup case=disabled containers=0\n"
        enabled = enabled_stages + b"image_runtime case=enabled previous_id=x\n"
        enabled_cleanup = b"image_runtime_cleanup case=enabled containers=0\n"
        self.assertEqual(
            proof.immutable_failure_code(b""),
            "immutable_disabled_runtime",
        )
        for index, stage in enumerate(proof.IMMUTABLE_STAGES, start=1):
            self.assertEqual(
                proof.immutable_failure_code(
                    b"".join(disabled_stages.splitlines(keepends=True)[:index])
                ),
                f"immutable_disabled_{stage}",
            )
        self.assertEqual(
            proof.immutable_failure_code(disabled),
            "immutable_disabled_cleanup",
        )
        self.assertEqual(
            proof.immutable_failure_code(disabled + disabled_cleanup),
            "immutable_enabled_runtime",
        )
        self.assertEqual(
            proof.immutable_failure_code(disabled + disabled_cleanup + enabled),
            "immutable_enabled_cleanup",
        )
        self.assertEqual(
            proof.immutable_failure_code(
                disabled + disabled_cleanup + enabled + enabled_cleanup
            ),
            "immutable_filesystem_tail",
        )
        self.assertEqual(
            proof.immutable_failure_code(disabled + disabled),
            "immutable_marker_contract",
        )
        self.assertEqual(
            proof.failure_for_phase(
                "immutable_runtime",
                proof.ProofFailure("immutable_enabled_runtime"),
            ),
            {
                "stage": "immutable_runtime",
                "code": "immutable_enabled_runtime",
            },
        )

    def test_immutable_stage_unknown_is_marker_contract(self) -> None:
        self.assertEqual(
            proof.immutable_failure_code(
                b"image_runtime_stage case=disabled stage=raw-output\n"
            ),
            "immutable_marker_contract",
        )
        self.assertEqual(
            proof.immutable_failure_code(
                b"image_runtime_stage case=other stage=fixture_ready\n"
            ),
            "immutable_marker_contract",
        )

    def test_immutable_stage_duplicate_is_marker_contract(self) -> None:
        marker = b"image_runtime_stage case=disabled stage=fixture_ready\n"
        self.assertEqual(
            proof.immutable_failure_code(marker + marker),
            "immutable_marker_contract",
        )

    def test_immutable_stage_out_of_order_is_marker_contract(self) -> None:
        self.assertEqual(
            proof.immutable_failure_code(
                b"image_runtime_stage case=disabled stage=previous_compose_ready\n"
            ),
            "immutable_marker_contract",
        )
        self.assertEqual(
            proof.immutable_failure_code(
                b"image_runtime_stage case=enabled stage=fixture_ready\n"
            ),
            "immutable_marker_contract",
        )

    def test_duplicate_required_marker_rejected(self) -> None:
        value = proof.initial_evidence("a" * 40, "b" * 40)
        with mock.patch.object(
            proof,
            "bounded_run",
            return_value=proof.RunResult(0, b"required\nrequired\n"),
        ):
            assert_failure(
                self,
                lambda: proof.run_subject_suite(
                    value,
                    suite="retention",
                    argv=["fixture"],
                    subject=HERE,
                    env={"PATH": os.defpath},
                    timeout_seconds=1,
                    markers=(b"required",),
                ),
            )

    def test_duplicate_descriptor_markers_rejected(self) -> None:
        records = json.dumps(
            passing_proof()["suites"]["filesystem"]["descriptorFailures"],
            separators=(",", ":"),
            sort_keys=True,
        )
        result_marker = f"MEE2_DESCRIPTOR_RESULT={records}\n".encode()
        failure_marker = (
            b'MEE2_DESCRIPTOR_FAILURE={"code":"descriptor_coverage","stage":"descriptor"}\n'
        )
        self.assertIsNone(proof.parse_descriptor_result(result_marker + result_marker))
        self.assertIsNone(
            proof.parse_descriptor_result(result_marker + b"MEE2_DESCRIPTOR_RESULT={}\n")
        )
        self.assertIsNone(proof.parse_descriptor_failure(failure_marker + failure_marker))

    def test_descriptor_growth_rejects_zero_exit_contract(self) -> None:
        value = passing_proof()
        records = value["suites"]["filesystem"]["descriptorFailures"]
        records["transferred_missing"]["maxFdGrowthBeforeRescue"] = 1
        proof.apply_descriptor_result(value, records)
        self.assertFalse(
            proof.descriptor_result_is_passing(value, proof.RunResult(0, b""))
        )
        self.assertEqual(value["verdict"], "failed")

    def test_retention_boundary_requires_owner_and_terminal_witnesses(self) -> None:
        with self.assertRaises(AssertionError):
            required_retention_witnesses({"terminal.json": object()}, "provider-owner.json")
        self.assertEqual(
            required_retention_witnesses(
                {"provider-owner.json": object(), "terminal.json": object()},
                "provider-owner.json",
            ),
            ("provider-owner.json", "terminal.json"),
        )

    def test_normalized_postgres_repo_digest(self) -> None:
        ref = proof.IMAGES["postgres"]
        digest = ref.rsplit("@", 1)[1]
        self.assertTrue(proof.repo_digest_matches(ref, f"postgres@{digest}"))
        self.assertFalse(proof.repo_digest_matches(ref, f"wrong-repository@{digest}"))
        self.assertFalse(proof.repo_digest_matches(ref, "postgres@sha256:" + "0" * 64))

    def test_literal_cleanup_separator(self) -> None:
        subject = subprocess.run(
            ["git", "show", f"{INVENTORY['subject']['commit']}:scripts/test-test-vps-provider-runtime.sh"],
            check=True,
            capture_output=True,
            timeout=30,
        ).stdout
        self.assertIn(b"image_runtime_cleanup case=", subject)

    def test_exit_77(self) -> None:
        value = passing_proof()
        value["verdict"] = "environment_blocked"
        value["suites"]["filesystem"]["status"] = "environment_blocked"
        proof.validate_proof(value)

    def test_timeout_child_tree(self) -> None:
        child_grandchild_timeout_fixture()
        result = proof.bounded_run(
            [sys.executable, "-c", "import time; time.sleep(3)"],
            cwd=HERE,
            timeout_seconds=0.1,
            env={"PATH": os.defpath},
        )
        self.assertTrue(result.timed_out)

    def test_pre_initialization_failure_cleanup_not_run(self) -> None:
        value = proof.safe_failure_proof("a" * 40, "b" * 40)
        self.assertTrue(all(status == "not_run" for status in value["cleanup"].values()))
        self.assertEqual(value["failure"], {"stage": "none", "code": "none"})
        proof.validate_proof(value)

    def test_failure_observation_is_allowlisted(self) -> None:
        self.assertEqual(
            proof.failure_observation("descriptor", "timeout_tree"),
            {"stage": "descriptor", "code": "timeout_tree"},
        )
        value = passing_proof()
        value["failure"] = {"stage": "descriptor", "code": "raw-output"}
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_capture_overflow(self) -> None:
        result = proof.bounded_run(
            [sys.executable, "-c", "import sys; sys.stdout.write('x' * 9000000)"],
            cwd=HERE,
            timeout_seconds=30,
            env={"PATH": os.defpath},
        )
        self.assertTrue(result.overflow)
        self.assertLessEqual(len(result.output), proof.MAX_CAPTURE)

    def test_secret_sentinel(self) -> None:
        assert_failure(self, lambda: proof.validate_secret_free(b"PRIVATE_KEY"))

    def test_unknown_schema_field(self) -> None:
        value = passing_proof()
        value["unexpected"] = True
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_archive_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "bad.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("../proof.json", b"{}")
                bundle.writestr("SHA256SUMS", b"")
            assert_failure(
                self,
                lambda: proof.verify_archive(str(archive), "a" * 64, "a" * 40),
            )

    def test_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.mkdir(exist_ok=True)
            value = passing_proof()
            data = json.dumps(value, separators=(",", ":"), sort_keys=True).encode() + b"\n"
            (root / "proof.json").write_bytes(data)
            (root / "SHA256SUMS").write_text("0" * 64 + "  proof.json\n", encoding="ascii")
            assert_failure(self, lambda: proof.validate_evidence_root(str(root)))

    def test_archive_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence"
            proof.write_evidence(evidence, passing_proof())
            archive = root / "evidence.zip"
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
                bundle.write(evidence / "proof.json", "proof.json")
                bundle.write(evidence / "SHA256SUMS", "SHA256SUMS")
            proof.verify_archive(
                str(archive),
                hashlib.sha256(archive.read_bytes()).hexdigest(),
                "a" * 40,
            )

    def test_evidence_read_access_is_limited_to_sanitized_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "evidence"
            proof.write_evidence(root, passing_proof())
            proof.grant_evidence_read_access(root)
            self.assertEqual(sorted(item.name for item in root.iterdir()), ["SHA256SUMS", "proof.json"])
            proof.validate_evidence_root(str(root))

    def test_foreign_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "child"
            child.mkdir()
            foreign = root / "foreign"
            foreign.write_bytes(b"keep")
            self.assertTrue(proof.remove_owned_tree(child, proof.lstat_identity(child)))
            self.assertEqual(foreign.read_bytes(), b"keep")

    def test_replaced_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "owned"
            root.mkdir()
            identity = proof.lstat_identity(root)
            root.rename(Path(directory) / "replaced")
            self.assertFalse(proof.remove_owned_tree(root, identity))
            (Path(directory) / "replaced").rmdir()

    def test_docker_inspect_error(self) -> None:
        value = passing_proof()
        value["images"]["target"]["imageId"] = "not-an-id"
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_cleanup_residue(self) -> None:
        self.assertIsInstance(proof.check_fixed_cleanup(), bool)

    def test_missing_upload_receipt(self) -> None:
        workflow = (HERE.parent / ".github/workflows/prove-mee2-93-hosted.yml").read_text()
        self.assertIn("artifact-id", workflow)
        self.assertIn("artifact-digest", workflow)
        self.assertIn('[[ "$ARTIFACT_DIGEST" =~ ^[0-9a-f]{64}$ ]]', workflow)
        self.assertIn('echo "- Artifact digest: sha256:$ARTIFACT_DIGEST"', workflow)

    def test_trigger_path_permission_retention_contract(self) -> None:
        workflow = (HERE.parent / ".github/workflows/prove-mee2-93-hosted.yml").read_text()
        self.assertEqual(workflow.count("pull_request:"), 1)
        self.assertEqual(workflow.count("push:"), 0)
        self.assertEqual(workflow.count("schedule:"), 0)
        self.assertIn("contents: read", workflow)
        self.assertIn("retention-days: 90", workflow)
        for path in (
            ".github/workflows/prove-mee2-93-hosted.yml",
            "scripts/mee2-93-hosted-cases.json",
            "scripts/mee2-93-hosted-proof.py",
            "scripts/prove-mee2-93-hosted.sh",
            "scripts/test-mee2-93-hosted-proof.py",
        ):
            self.assertIn(path, workflow)
        mode = subprocess.check_output(
            ["git", "ls-files", "-s", "scripts/prove-mee2-93-hosted.sh"],
            text=True,
            timeout=30,
        ).split()[0]
        self.assertEqual(mode, "100755")

    def test_timeout_orphaned_pipe_tree(self) -> None:
        if os.name != "posix" or sys.platform != "linux":
            return
        result = subprocess.run(
            [sys.executable, str(HERE / "test-mee2-93-hosted-proof.py"), "--orphaned-pipe-fixture"],
            cwd=HERE,
            capture_output=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0)

    def test_descriptor_growth_fails_verdict(self) -> None:
        value = passing_proof()
        value["suites"]["filesystem"]["descriptorFailures"]["transferred_missing"][
            "maxFdGrowthBeforeRescue"
        ] = 1
        assert_failure(self, lambda: proof.validate_proof(value))

    def test_descriptor_rescue_cannot_clear_failure(self) -> None:
        value = passing_proof()
        record = value["suites"]["filesystem"]["descriptorFailures"]["transferred_replaced_regular"]
        record["maxFdGrowthBeforeRescue"] = 2
        proof.validate_descriptor_sticky(value)
        self.assertEqual(value["verdict"], "failed")

    def test_descriptor_measurements_closed_schema(self) -> None:
        value = passing_proof()
        value["suites"]["filesystem"]["descriptorFailures"]["retention_post_acquisition"]["rawFdMap"] = {}
        assert_failure(self, lambda: proof.validate_proof(value))


def fd_set() -> set[int]:
    scan_fd = os.open("/proc/self/fd", os.O_RDONLY | os.O_DIRECTORY)
    try:
        scan_info = os.fstat(scan_fd)
        result: set[int] = set()
        for name in os.listdir(scan_fd):
            if not name.isdigit() or int(name) == scan_fd:
                continue
            fd = int(name)
            try:
                info = os.fstat(fd)
            except OSError:
                continue
            if (info.st_dev, info.st_ino) == (scan_info.st_dev, scan_info.st_ino):
                continue
            result.add(fd)
        return result
    finally:
        os.close(scan_fd)


def safe_remove(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_symlink() or not path.is_dir():
        path.unlink()
        return
    for child in list(path.iterdir()):
        safe_remove(child)
    path.rmdir()


def write_owned_file(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, data)
        os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


def expect_recovery(helper: Any, action: Callable[[], Any]) -> None:
    try:
        action()
    except helper.ProviderError as error:
        if error.category != helper.ERRORS["recovery"]:
            raise AssertionError("wrong recovery category")
    else:
        raise AssertionError("missing RECOVERY_REQUIRED")


def close_ledger_fds(
    baseline: set[int],
    ledger: set[int],
    identity_by_fd: dict[int, dict[str, int]],
) -> int:
    current = fd_set()
    leaked = current - baseline
    if not leaked.issubset(ledger):
        raise AssertionError("unknown descriptor ownership")
    growth = len(leaked)
    for fd in sorted(leaked):
        expected = identity_by_fd.get(fd)
        if expected is None:
            raise AssertionError("unregistered descriptor")
        try:
            actual = os.fstat(fd)
        except OSError as error:
            raise AssertionError("descriptor disappeared from ledger") from error
        if (int(actual.st_dev), int(actual.st_ino)) != (
            expected["device"], expected["inode"]
        ):
            raise AssertionError("descriptor identity changed")
        os.close(fd)
    return growth


def direct_witness_loop(helper: Any, fixture: Path, kind: str) -> tuple[str, int, int]:
    directory = fixture / f"witness-{kind}"
    directory.mkdir(mode=0o700)
    os.chown(directory, 0, 0)
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    baseline = fd_set()
    max_growth = 0
    failed = False
    try:
        for index in range(100):
            name = f"child-{index}"
            child = directory / name
            data = f"descriptor-{kind}-{index}".encode()
            write_owned_file(child, data)
            identity, returned = helper._child_witness(directory_fd, name)
            if returned != data:
                raise AssertionError("witness bytes changed")
            witness_fd = identity.get("_witnessFd")
            if not isinstance(witness_fd, int):
                raise AssertionError("witness descriptor was not transferred")
            expected = dict(identity)
            if kind == "missing":
                child.unlink()
            elif kind == "regular":
                child.unlink()
                write_owned_file(child, b"replacement")
            else:
                child.unlink()
                target = directory / f"target-{index}"
                write_owned_file(target, b"symlink-target")
                os.symlink(target.name, child)
            try:
                helper._witnessed_unlink(
                    directory_fd,
                    name,
                    expected_identity=expected,
                    expected_data=data,
                    uid=0,
                    gid=0,
                    mode=0o600,
                    link_count=1,
                )
            except helper.ProviderError as error:
                if error.category != helper.ERRORS["recovery"]:
                    raise AssertionError("wrong recovery category")
            else:
                failed = True
            growth = close_ledger_fds(
                baseline, {witness_fd}, {witness_fd: identity}
            )
            max_growth = max(max_growth, growth)
            if kind == "missing":
                if child.exists() or child.is_symlink():
                    raise AssertionError("missing child was recreated")
            elif kind == "regular":
                if child.read_bytes() != b"replacement":
                    raise AssertionError("regular replacement changed")
                child.unlink()
            else:
                if not child.is_symlink() or os.readlink(child) != target.name:
                    raise AssertionError("symlink replacement changed")
                child.unlink()
                target.unlink()
        return ("failed" if failed or max_growth else "passed"), 100, max_growth
    finally:
        os.close(directory_fd)
        safe_remove(directory)


def successful_child_witness_contract(helper: Any, fixture: Path) -> None:
    directory = fixture / "successful-witness"
    directory.mkdir(mode=0o700)
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for index in range(100):
            name = f"child-{index}"
            child = directory / name
            data = f"successful-witness-{index}".encode()
            write_owned_file(child, data)
            baseline = fd_set()
            identity, returned = helper._child_witness(directory_fd, name)
            witness_fd = identity.get("_witnessFd")
            if not isinstance(witness_fd, int) or returned != data:
                raise proof.ProofFailure("subject_child_success_data")
            after_acquire = fd_set()
            delta = after_acquire - baseline
            if witness_fd not in delta:
                raise proof.ProofFailure("subject_child_success_fd_missing")
            if delta != {witness_fd}:
                raise proof.ProofFailure("subject_child_success_fd_extra")
            os.fstat(witness_fd)
            os.close(witness_fd)
            if fd_set() != baseline:
                raise proof.ProofFailure("subject_child_success_close")
            child.unlink()
    finally:
        os.close(directory_fd)
        safe_remove(directory)


def successful_retention_delete(helper: Any, fixture: Path) -> None:
    for index in range(100):
        state_root, state, _, _ = retention_state(helper, fixture, index + 1000)
        baseline = fd_set()
        helper._retention_delete(str(state_root), str(state))
        if state.exists() or fd_set() != baseline:
            raise AssertionError("successful retention deletion violated fixture contract")
        safe_remove(state_root)


def child_admission_rejections(helper: Any, fixture: Path) -> None:
    directory = fixture / "witness-admission"
    directory.mkdir(mode=0o700)
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fifo = directory / "fifo"
        os.mkfifo(fifo, 0o600)
        baseline = fd_set()
        expect_recovery(helper, lambda: helper._child_witness(directory_fd, "fifo"))
        if fd_set() != baseline:
            raise AssertionError("FIFO rejection changed descriptor baseline")
        fifo.unlink()
        oversized = directory / "oversized"
        with oversized.open("wb") as stream:
            stream.truncate(helper.MAX_WITNESS_BYTES + 1)
        baseline = fd_set()
        expect_recovery(helper, lambda: helper._child_witness(directory_fd, "oversized"))
        if fd_set() != baseline:
            raise AssertionError("oversize rejection changed descriptor baseline")
        oversized.unlink()
    finally:
        os.close(directory_fd)
        safe_remove(directory)


def admission_rejection_contract(helper: Any, fixture: Path) -> None:
    state_root, state, _, _ = retention_state(helper, fixture, 2000)
    (state / "terminal.json").unlink()
    baseline = fd_set()
    expect_recovery(helper, lambda: helper._retention_delete(str(state_root), str(state)))
    if fd_set() != baseline:
        raise AssertionError("admission rejection changed descriptor baseline")
    safe_remove(state_root)


def retention_state(helper: Any, fixture: Path, index: int) -> tuple[Path, Path, bytes, bytes]:
    state_root = fixture / f"retention-root-{index}"
    state_root.mkdir(mode=0o700)
    os.chown(state_root, 0, 0)
    name = f"{100000 + index}-1-final-deploy"
    state = state_root / name
    state.mkdir(mode=0o700)
    os.chown(state, 0, 0)
    marker = json.dumps(
        {
            "schemaVersion": 1,
            "owner": helper.OWNER,
            "runKey": f"{100000 + index}-1",
            "stateKind": "final-deploy",
        },
        separators=(",", ":"),
    ).encode()
    terminal = json.dumps(
        {
            "schemaVersion": 1,
            "runKey": f"{100000 + index}-1",
            "outcome": "committed",
            "providerEnabled": False,
        },
        separators=(",", ":"),
    ).encode()
    write_owned_file(state / helper.OWNER_MARKER, marker)
    write_owned_file(state / "terminal.json", terminal)
    return state_root, state, marker, terminal


def required_retention_witnesses(
    witnesses: dict[str, Any],
    owner_marker: str,
) -> tuple[str, str]:
    required = (owner_marker, "terminal.json")
    if any(name not in witnesses for name in required):
        raise AssertionError("retention witness boundary missing owner or terminal")
    return required


def retention_loop(helper: Any, fixture: Path) -> tuple[str, int, int]:
    max_growth = 0
    failed = False
    boundary = False
    for index in range(100):
        state_root, state, marker, terminal = retention_state(helper, fixture, index)
        root_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        baseline = fd_set()
        seen: dict[str, Any] = {"boundary": False, "identities": {}}

        def trace(frame: Any, event: str, arg: Any) -> Any:
            if (
                event == "call"
                and frame.f_code.co_name == "_reject_protected_reference_aliases"
            ):
                caller = frame.f_back
                witnesses = caller.f_locals.get("witnesses") if caller else None
                if not isinstance(witnesses, dict):
                    raise AssertionError("witness acquisition boundary missing")
                required = required_retention_witnesses(witnesses, helper.OWNER_MARKER)
                seen["boundary"] = True
                for identity, _ in witnesses.values():
                    fd = identity.get("_witnessFd")
                    if not isinstance(fd, int) or fd not in fd_set():
                        raise AssertionError("witness was not open at boundary")
                    seen["identities"][fd] = {
                        "device": identity["device"],
                        "inode": identity["inode"],
                    }
                interlock = state_root / ".provider-transaction.current"
                fd = os.open(
                    interlock,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                )
                os.fchown(fd, 0, 0)
                os.close(fd)
            return trace

        before = {
            "marker": (state / helper.OWNER_MARKER).read_bytes(),
            "terminal": (state / "terminal.json").read_bytes(),
        }
        previous_trace = sys.gettrace()
        sys.settrace(trace)
        try:
            expect_recovery(
                helper,
                lambda: helper._retention_delete(str(state_root), str(state)),
            )
        finally:
            sys.settrace(previous_trace)
        boundary = boundary or bool(seen["boundary"])
        after = fd_set()
        leaked = after - baseline
        if not leaked.issubset(seen["identities"]):
            raise AssertionError("retention leaked an unknown descriptor")
        growth = len(leaked)
        max_growth = max(max_growth, growth)
        if growth:
            failed = True
        close_ledger_fds(baseline, set(seen["identities"]), seen["identities"])
        interlock = state_root / ".provider-transaction.current"
        if interlock.exists():
            interlock.unlink()
        if (
            (state / helper.OWNER_MARKER).read_bytes() != before["marker"]
            or (state / "terminal.json").read_bytes() != before["terminal"]
        ):
            raise AssertionError("retention fixture mutated")
        os.close(root_fd)
        safe_remove(state_root)
    if not boundary:
        raise AssertionError("post-acquisition boundary was not reached")
    return ("failed" if failed or max_growth else "passed"), 100, max_growth


def native_descriptor(subject_value: str) -> int:
    results = {
        key: {
            "status": "not_run",
            "iterations": 0,
            "maxFdGrowthBeforeRescue": None,
        }
        for key in proof.DESCRIPTOR_KEYS
    }
    failure_stage = "descriptor"
    failure_code = "subject_identity"
    try:
        if os.name != "posix" or sys.platform != "linux" or os.geteuid() != 0:
            raise proof.ProofFailure("linux_prerequisite", environment=True)
        child_grandchild_timeout_fixture()
        orphaned_pipe_timeout_fixture()
        failure_stage = "subject"
        subject = proof.absolute_dir(subject_value, existing=True)
        proof.subject_identity(subject)
        helper_path = subject / "scripts/test-vps-provider-credential.py"
        expected_hashes = {item["path"]: item["sha256"] for item in SUBJECT_FILES}
        if proof.sha256_file(helper_path) != expected_hashes[
            "scripts/test-vps-provider-credential.py"
        ]:
            raise proof.ProofFailure("helper_drift")
        spec = importlib.util.spec_from_file_location("mee2_95_subject_helper", helper_path)
        if spec is None or spec.loader is None:
            raise proof.ProofFailure("helper_load")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        if os.path.lexists("/var/lib/meet-production"):
            raise proof.ProofFailure("foreign_root", environment=True)
        fixture = Path(f"/var/lib/mee2-95-descriptor.{os.getpid()}")
        fixture.mkdir(mode=0o700)
        os.chown(fixture, 0, 0)
        try:
            failure_code = "subject_child_admission"
            child_admission_rejections(helper, fixture)
            failure_code = "subject_child_success"
            successful_child_witness_contract(helper, fixture)
            failure_code = "subject_retention_success"
            successful_retention_delete(helper, fixture)
            failure_code = "subject_retention_admission"
            admission_rejection_contract(helper, fixture)
            failure_code = "subject_witness_loop"
            for key, kind in (
                ("transferred_missing", "missing"),
                ("transferred_replaced_regular", "regular"),
                ("transferred_replaced_symlink", "symlink"),
            ):
                status, iterations, growth = direct_witness_loop(helper, fixture, kind)
                results[key] = {
                    "status": status,
                    "iterations": iterations,
                    "maxFdGrowthBeforeRescue": growth,
                }
            failure_code = "subject_retention_loop"
            status, iterations, growth = retention_loop(helper, fixture)
            results["retention_post_acquisition"] = {
                "status": status,
                "iterations": iterations,
                "maxFdGrowthBeforeRescue": growth,
            }
        finally:
            safe_remove(fixture)
        proof.subject_identity(subject)
    except proof.ProofFailure as error:
        if error.environment:
            failure = proof.failure_observation(failure_stage, "environment")
        elif failure_stage == "descriptor":
            failure = proof.failure_observation("descriptor", "descriptor_coverage")
        elif error.code in ("subject_sha", "subject_tree", "subject_file"):
            failure = proof.failure_observation("subject", "subject_identity")
        elif error.code in ("helper_drift", "helper_load"):
            failure = proof.failure_observation("subject", "subject_helper")
        elif error.code in proof.FAILURE_CODES:
            failure = proof.failure_observation("subject", error.code)
        else:
            failure = proof.failure_observation("subject", failure_code)
        print("MEE2_DESCRIPTOR_FAILURE=" + json.dumps(failure, separators=(",", ":"), sort_keys=True))
        print("MEE2_DESCRIPTOR_RESULT=" + json.dumps(results, separators=(",", ":"), sort_keys=True))
        return 77 if error.environment else 1
    except (AssertionError, OSError, ValueError, ImportError):
        code = "timeout_tree" if failure_stage == "descriptor" else failure_code
        failure = proof.failure_observation(failure_stage, code)
        print("MEE2_DESCRIPTOR_FAILURE=" + json.dumps(failure, separators=(",", ":"), sort_keys=True))
        print("MEE2_DESCRIPTOR_RESULT=" + json.dumps(results, separators=(",", ":"), sort_keys=True))
        return 1
    print("MEE2_DESCRIPTOR_FAILURE=" + json.dumps(
        proof.failure_observation(), separators=(",", ":"), sort_keys=True
    ))
    print("MEE2_DESCRIPTOR_RESULT=" + json.dumps(results, separators=(",", ":"), sort_keys=True))
    return 0 if all(item["status"] == "passed" for item in results.values()) else 1


def main() -> int:
    if "--orphaned-pipe-fixture" in sys.argv:
        orphaned_pipe_timeout_fixture()
        return 0
    if "--linux-runtime" in sys.argv:
        subject_index = sys.argv.index("--subject")
        if subject_index + 1 >= len(sys.argv):
            return 2
        return native_descriptor(sys.argv[subject_index + 1])
    program = unittest.main(module=__name__, argv=[sys.argv[0]], exit=False)
    return 0 if program.result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
