#!/usr/bin/env python3
"""Synthetic on-disk recovery cases; runtime responses, never helper substitutes."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
import time


SOURCE = pathlib.Path(__file__).resolve().parents[2]


def stage_tooling(tools: pathlib.Path) -> None:
    for name in (
        "deploy-test-vps-provider-release.sh", "production-compose.sh",
        "update-production-release.sh", "test-vps-runtime-invariants.sh",
        "production-config-digest.sh",
        "test-vps-provider-credential.py", "test_vps_timepad_state.py",
        "test_vps_timepad_supervisor.py", "test_vps_timepad_create.py",
    ):
        shutil.copy2(SOURCE / name, tools / name)
    for name in ("create-controller.py", "forward.py", "recovery.py"):
        shutil.copy2(pathlib.Path(__file__).with_name(name), tools / name)


def historical_lease(module, attempt, *, owner: dict, workers: list, worker=None) -> dict:
    # These historical start/stop cases never executed a create request.
    return module._execution_lease(dict(
        attempt.lease(), supervisor=owner, worker=worker,
        workerMode="controller-worker", workers=workers, createCompletion=None,
    ))


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    # These fixture modules import their reviewed sibling modules by their
    # production module names. Loading through an arbitrary file path does not
    # otherwise make that sibling directory importable.
    sys.path.insert(0, str(path.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(path.parent))
    return module


def case_helpers(case: pathlib.Path):
    # Import the actual staged helpers beside their admitted fixture contract.
    # The provider's fixed module cache must not reuse SOURCE's inactive one.
    module = load(
        "test_vps_timepad_state_for_provider_retention",
        case / "tools/test_vps_timepad_state.py",
    )
    provider = load("recovery_case_provider", case / "tools/test-vps-provider-credential.py")
    return provider, module


def private(path: pathlib.Path, data: bytes) -> None:
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def identity(path: pathlib.Path) -> bytes:
    info = path.stat()
    return (
        f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
        f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}\n"
    ).encode()


def require_isolated(case: pathlib.Path) -> None:
    # The shell harness has already proved fresh, private fixed-path mounts.
    # Refuse a direct invocation outside that harness's namespace.
    if sys.platform != "linux" or os.geteuid() != 0 or not str(case).startswith(
        "/var/lib/timepad-fixture/case-"
    ):
        raise SystemExit("isolated Linux fixture is required")
    for namespace, variable in (
        ("mnt", "TIMEPAD_FIXTURE_PARENT_MOUNT_NS"),
        ("net", "TIMEPAD_FIXTURE_PARENT_NETWORK_NS"),
        ("pid", "TIMEPAD_FIXTURE_PARENT_PID_NS"),
    ):
        parent = os.environ.get(variable)
        if parent is None or parent == os.readlink(f"/proc/self/ns/{namespace}"):
            raise SystemExit("fixture namespace isolation is unproved")
    mounts = pathlib.Path("/proc/self/mountinfo").read_text().splitlines()
    if not any(
        line.split()[4] == "/var/lib" and " - tmpfs " in line
        and not any(field.startswith(("shared:", "master:")) for field in line.split())
        for line in mounts
    ):
        raise SystemExit("fixture fixed-path isolation is unproved")


def historical_cutover_state(module, prepared: dict, *, container_id: str, config_hash: str) -> dict:
    """Historical recovery input, not evidence of PREPARED → create execution."""
    return module._current(dict(
        prepared, phase="CUTOVER_POSSIBLE", containerId=container_id, configHash=config_hash,
    ))


def setup(
    case: pathlib.Path, phase: str, fault: str, *,
    compatible: bool = True, request_proof: bool = False,
) -> None:
    require_isolated(case)
    proof_faults = {"intact", "foreign", "foreign-provider", "missing-request-proof", "reaped-child"}
    if request_proof and not (
        phase == "CUTOVER_POSSIBLE" and fault in proof_faults
        or phase in {"VERIFYING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"} and fault == "intact"
        or phase == "ROLLING_BACK" and fault in {"intact", "foreign", "missing-input"}
        or phase == "COMMITTING" and fault in {
            "intact", "unknown-inventory", "create-intent", "create-fails", "replace",
        }
    ):
        raise SystemExit("request proof requires an admitted exact-retry fixture")
    request_proof = request_proof or (
        phase == "CUTOVER_POSSIBLE" and fault in proof_faults - {"intact"}
    )
    fixtures = load("provider_recovery_fixtures", SOURCE / "test-test-vps-provider-credential.py")
    module, contract, _, template, envelope = fixtures.live_context(phase)
    external = load("historical_external_facts", pathlib.Path(__file__).with_name("forward.py"))
    # The legacy request branch admits only pinned external tooling. It does
    # not acquire a create model/resource proof or a fabricated PREPARED receipt.
    contract["tooling"] = external.fixture_data(SOURCE)["contract"]["tooling"]
    if not compatible:
        contract["transitions"][0]["compatiblePredecessors"] = []
    root, state_root, tools = (case / name for name in ("root", "state", "tools"))
    for directory in (case, root, state_root, tools):
        directory.mkdir(mode=0o700)
    stage_tooling(tools)
    private(case / "docker.log", b"")
    private(tools / "test-vps-timepad-release-contracts.json", json.dumps(contract).encode())
    provider = fixtures.helper
    with module.deploy_lock(state_root):
        provider._state_publish(str(state_root), template["runId"], "final-deploy")
    authority = dict(
        rootId="test-root", bootstrapId="fixture-bootstrap",
        initialRuntime="a" * 64, initialConfig="b" * 64,
        initialSchema="c" * 64, initialStartupInventory="d" * 64,
        schemaHistoryProvenance=True,
    )
    observed = dict(
        rootId="test-root", runtime="a" * 64, config="b" * 64,
        schema="c" * 64, startupInventory="d" * 64, schemaHistoryProvenance=True,
    )
    module.bootstrap_guard(state_root, authority=authority, observed=observed)
    origin, ready = module.read_guard(state_root)
    admission = module.admit(
        contract, root_id="test-root", target_id="target", predecessor_id="previous",
        transition_id="first-timepad", target_tuple=template["target"]["tuple"],
        predecessor_tuple=template["predecessor"]["tuple"],
    )
    current = module.new_prepared_state(
        ready, operation="deploy", run_id=template["runId"],
        incident_id=template["incidentId"], admission=admission,
        target=template["target"], predecessor=template["predecessor"],
        predecessor_container_id="e" * 64, transition_id="first-timepad",
        owned_run=template["ownedRun"], tooling_digest=template["toolingDigest"],
        prepared_proof_digest=template["preparedProofDigest"],
    )
    if phase == "PREPARED":
        module.publish_current(state_root, current)
    else:
        current = historical_cutover_state(
            module, current, container_id=template["containerId"], config_hash=template["configHash"],
        )
        # Import a schema-validated historical snapshot for recovery tests.
        # This is not a transition, a create completion, or a worker grant.
        # Fresh PREPARED → create tests must use the actual controller path.
        with module.deploy_lock(state_root):
            guard_fd = os.open(
                state_root / module.GUARD_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            try:
                module._atomic_write(
                    guard_fd, "current.json", module._canonical(current),
                    module.MAX_CURRENT_BYTES, replace=True,
                )
            finally:
                os.close(guard_fd)
        if phase != "CUTOVER_POSSIBLE":
            current = module.advance_state(current, "VERIFYING" if phase == "COMMITTING" else phase)
            module.publish_current(state_root, current)
        if fault == "orphan-child" or phase == "COMMITTING":
            child = subprocess.Popen(
                [sys.executable, "-B", "-c", "import sys; sys.stdin.buffer.read()"],
                stdin=subprocess.PIPE, start_new_session=True,
            )
            try:
                record = module.capture_owned_child(
                    child.pid, command_digest="1" * 64,
                    attempt_id=current["incidentId"] + ":1",
                )
                current = module.advance_state(
                    current, current["phase"], ownedChild=record, latestAttemptId=record["attemptId"],
                )
                module.publish_current(state_root, current)
                current = module.advance_state(
                    current, current["phase"], ownedChild=dict(record, lifecycle="released"),
                )
                module.publish_current(state_root, current)
            finally:
                assert child.stdin is not None
                child.stdin.close()
                child.wait(timeout=5)
            if phase == "COMMITTING":
                current = module.advance_state(
                    current, current["phase"], ownedChild=dict(record, lifecycle="reaped"),
                )
                module.publish_current(state_root, current)
                current = module.advance_state(current, current["phase"], ownedChild=None)
                module.publish_current(state_root, current)
    auth = dict(
        envelope["authorization"], originDigest=origin["originDigest"],
        evidenceDigest=current["evidenceDigest"],
    )
    private(state_root / "timepad-recovery-authorization.json", json.dumps(auth).encode())
    image = current["target"]["tuple"]
    env = (
        f'BACKEND_IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3@sha256:{image["repositoryDigest"]}\n'
        f'BACKEND_REVISION={image["revision"]}\nBACKEND_VERSION={image["version"]}\n'
    ).encode()
    private(root / ".env.production", env)
    compose = SOURCE / "fixtures/timepad-controller/compose.yml"
    private(root / "docker-compose.production.yml", compose.read_bytes())
    private(case / "compose.yml", compose.read_bytes())
    run = state_root / current["ownedRun"]
    for name, source in (
        ("config.env.target", root / ".env.production"),
        ("config.base-compose.yml", case / "compose.yml"),
    ):
        private(run / name, source.read_bytes())
        private(run / (name + ".identity"), identity(source))
    private(run / "target-runtime.override.yml", b"services:\n  backend: {}\n")
    private(state_root / ".provider-transaction.current", json.dumps(dict(
        schemaVersion=1, runKey=current["runId"], phase=(
            "rolling-back" if phase == "ROLLING_BACK" else "verifying"
        ), providerEnabled=False, durableDisposition="none",
    )).encode())
    inspection = envelope["inspection"][0]
    if phase == "COMMITTING":
        commit = dict(
            schema="meet-backend/test-vps-timepad-commit-witness/v1",
            operationEpoch=current["operationEpoch"], incidentId=current["incidentId"],
            containerId=current["containerId"], configHash=current["configHash"],
            imageId=inspection["Image"], revision=image["revision"],
            version=image["version"], providerEnabled=False,
        )
        commit_data = json.dumps(commit, sort_keys=True, separators=(",", ":")).encode()
        private(run / "timepad-commit-witness.json", commit_data)
        run_fd = os.open(run, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            witness = provider._build_finalization_witness(
                run_key=current["runId"], state_kind="final-deploy", origin=origin,
                current=current, commit=commit, run_fd=run_fd,
                inspect=inspection, state_root=str(state_root),
            )
        finally:
            os.close(run_fd)
        witness_data = json.dumps(witness, sort_keys=True, separators=(",", ":")).encode()
        private(run / "provider-finalization.json", witness_data)
        current = module.advance_state(
            current, "COMMITTING", commitWitnessDigest=hashlib.sha256(commit_data).hexdigest(),
            providerFinalizationDigest=hashlib.sha256(witness_data).hexdigest(),
            commitSubstep="provider-cleanup",
        )
        module.publish_current(state_root, current)
        active = pathlib.Path("/var/lib/meet-production")
        active.mkdir(mode=0o700, exist_ok=True)
        for name, content in (("compose", compose.read_bytes()), ("runtime", b"services:\n  backend: {}\n")):
            path = active / ("active-compose.yml" if name == "compose" else "active-runtime.override.yml")
            if path.exists():
                path.unlink()  # Fixture-owned private tmpfs, never a host path.
            private(path, content)
            private(run / f"candidate-active-{name}.yml", content)
            private(run / f"candidate-active-{name}.identity", identity(path))
        if fault == "create-intent":
            current = module.advance_state(current, "FORWARD_RECOVERING")
            current = module.advance_state(
                current, "FORWARD_RECOVERING", commitSubstep="replacement-create-intent",
            )
            module.publish_current(state_root, current)
    inspection["State"]["Running"] = False
    inspection["State"]["Health"]["Status"] = "starting"
    # Inject faults only after obtaining the real historical daemon response.
    # In particular, absent-runtime tests cannot manufacture that response
    # from their later failed inspection or empty inventory.
    private(case / "fault", ("intact" if request_proof else fault).encode())
    if request_proof:
        # These cases obtain a real synchronous response from the runtime
        # adapter. The controller must not infer acknowledgment from inspect.
        private(case / "runtime.json", json.dumps(inspection).encode())
        setup_historical_request(
            case, current, module, provider, owned_start=fault == "reaped-child",
        )
    if fault == "foreign":
        inspection["Id"] = "a" * 64
        if request_proof:
            (case / "runtime.json").write_bytes(json.dumps(inspection).encode())
    if not request_proof:
        private(case / "runtime.json", json.dumps(inspection).encode())
    if fault == "foreign-provider":
        marker = state_root / ".provider-transaction.current"
        marker.write_bytes(json.dumps(dict(
            json.loads(marker.read_bytes()), runKey="foreign-provider-1",
        )).encode())
    (case / "fault").write_text(fault)
    private(case / "binding", current["evidenceDigest"].encode())
    if fault in {"missing-input", "active-child-missing-input"}:
        (run / "config.env.target").unlink()


def setup_historical_request(
    case: pathlib.Path, current: dict, module, provider, *, owned_start: bool,
) -> None:
    """Persist an actual daemon acknowledgment, with ECHILD before lease drain."""
    supervisor = load("historical_request_supervisor", SOURCE / "test_vps_timepad_supervisor.py")
    supervisor.linux_preflight()
    attempt = supervisor.Attempt("deploy", nonce="8" * 32)
    attempt.arm()
    owner = supervisor.lease_identity(supervisor.process_identity(os.getpid()))
    operation = "start" if owned_start else "stop"
    command = [sys.executable, "-B", __file__, "docker", operation, current["containerId"]]
    child = subprocess.Popen(
        [sys.executable, "-B", "-c",
         "import os, sys; "
         "assert sys.stdin.buffer.read(1) == b'1'; "
         "os.execv(sys.executable, sys.argv[1:])", *command],
        env=dict(os.environ, TIMEPAD_FIXTURE_CASE=str(case)),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        worker = supervisor.lease_identity(supervisor.process_identity(child.pid))
        record = module.capture_owned_child(
            child.pid, command_digest=hashlib.sha256(
                b"\0".join(os.fsencode(part) for part in command) + b"\0",
            ).hexdigest(), attempt_id=current["incidentId"] + ":1",
        )
        with module.deploy_lock(case / "state") as lock:
            guard_fd = os.open(
                case / "state" / module.GUARD_DIR,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            )
            try:
                def persist(**changes):
                    nonlocal current
                    current = module.advance_state(current, current["phase"], **changes)
                    # Fixture-only historical import: use real validation and
                    # durable publication, not a mocked private worker grant.
                    module._atomic_write(
                        guard_fd, "current.json", module._canonical(current),
                        module.MAX_CURRENT_BYTES, replace=True,
                    )

                if owned_start:
                    persist(
                        executionAttempt=attempt.nonce, ownedChild=record,
                        latestAttemptId=record["attemptId"],
                    )
                else:
                    persist(executionAttempt=attempt.nonce)
                request = dict(
                    nonce="9" * 32, sequence=1, executionAttempt=attempt.nonce,
                    operation=operation, containerId=current["containerId"],
                    imageId=current["target"]["tuple"]["platformImageId"],
                    configHash=current["configHash"],
                    childAttemptId=record["attemptId"] if owned_start else None,
                    lifecycle="intent", responseId=None, completionDigest=None,
                )
                persist(runtimeRequest=request)
                if owned_start:
                    persist(ownedChild=dict(record, lifecycle="released"))
                response, errors = child.communicate(b"1", timeout=5)
                if (
                    child.returncode != 0 or errors
                    or response != (current["containerId"] + "\n").encode()
                    or not supervisor.Children().reap()
                ):
                    raise SystemExit("historical request lacks exact daemon response or ECHILD")
                module.require_child_group_quiescent(record)
                request = dict(
                    request, lifecycle="acknowledged", responseId=response.decode().strip(),
                )
                persist(runtimeRequest=request)
                inspection = json.loads((case / "runtime.json").read_bytes())
                private(case / "historical-runtime.json", module._canonical(inspection))
                proof = provider._runtime_request_proof(current, inspection)
                persist(runtimeRequest=dict(
                    request, lifecycle="completed", completionDigest=proof["completionDigest"],
                ))
                staged_provider, _ = case_helpers(case)
                result = staged_provider._validate_live_resume(
                    current["runId"], str(case / "state"), "final-deploy",
                    json.dumps(dict(
                        schema=staged_provider.LIVE_RESUME_SCHEMA, stage="runtime",
                        authorization=json.loads((
                            case / "state/timepad-recovery-authorization.json"
                        ).read_bytes()),
                        inspection=[inspection],
                    )).encode(), lock,
                )
                if result[-1] != "retry-exact-candidate":
                    raise SystemExit("historical request lacks valid live/receipt recovery proof")
            finally:
                os.close(guard_fd)
        attempt.cancel("EXIT", 1)
        attempt.acknowledge_lease(
            attempt.revision, hashlib.sha256(module._canonical(attempt.lease())).hexdigest(),
        )
        attempt.prepare_terminal()
        lease = historical_lease(
            module, attempt, owner=owner, workers=[dict(mode="controller-worker", **worker)],
        )
        private(case / "state" / module.EXECUTION_LEASE_NAME, module._canonical(lease))
        private(case / "historical-before", module._canonical(current))
        # Setup exits before recovery; both actual recorded owners must be
        # absent then. In the owned-start case its released record stays stale.
    finally:
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=5)


def assert_historical_request(case: pathlib.Path) -> None:
    """Prove historical ownership, request completion, and prior kernel drain."""
    require_isolated(case)
    fault = (case / "fault").read_text()
    if fault not in {
        "reaped-child", "intact", "foreign", "foreign-provider", "missing-request-proof", "missing-input",
        "unknown-inventory", "create-intent", "create-fails", "replace",
    }:
        raise SystemExit("historical request assertion requires its scoped fixture")
    provider, module = case_helpers(case)
    with module.deploy_lock(case / "state"):
        _, current = module._read_guard_locked(case / "state")
        lease = module._read_execution_lease_locked(case / "state")
        child, request = current["ownedChild"], current["runtimeRequest"]
        if (
            lease is None or lease["lifecycle"] != "drained" or lease["worker"] is not None
            or current["executionAttempt"] != lease["attempt"]
            or request is None or request["operation"] != (
                "start" if fault == "reaped-child" else "stop"
            )
            or request["lifecycle"] != "completed" or request["sequence"] != 1
            or request["executionAttempt"] != lease["attempt"]
            or not all(module._execution_process_exited(owner) for owner in (
                lease["supervisor"], *lease["workers"],
            ))
        ):
            raise SystemExit("historical request lost correlated ownership/completion/drain")
        if fault == "reaped-child":
            if (
                current["phase"] != "CUTOVER_POSSIBLE"
                or child is None or child["lifecycle"] != "released"
                or request["childAttemptId"] != child["attemptId"]
                or not module._execution_process_exited(child)
            ):
                raise SystemExit("historical start lost its exited released-child proof")
            module.require_child_group_quiescent(child)
        elif (
            current["phase"] not in {
                "CUTOVER_POSSIBLE", "ROLLING_BACK", "COMMITTING", "FORWARD_RECOVERING",
            }
            or child is not None or request["childAttemptId"] is not None
        ):
            raise SystemExit("historical stop gained an unproved child or phase")
        acknowledged = dict(current, runtimeRequest=dict(
            request, lifecycle="acknowledged", completionDigest=None,
        ))
        proof = provider._runtime_request_proof(
            acknowledged, json.loads((case / "historical-runtime.json").read_bytes()),
        )
        if proof["completionDigest"] != request["completionDigest"]:
            raise SystemExit("historical request lost actual daemon completion")


def assert_bound_refusal(case: pathlib.Path) -> None:
    """Prove the private earliest gate after valid historical request evidence."""
    require_isolated(case)
    fault = (case / "fault").read_text()
    if fault not in {"foreign", "missing-input"}:
        raise SystemExit("bound refusal requires its scoped runtime/configuration fault")
    assert_historical_request(case)
    before = refusal_snapshot(case)
    _, module = case_helpers(case)
    state_root = case / "state"
    with module.deploy_lock(state_root) as lock:
        _, current = module._read_guard_locked(state_root)
        lease = module._read_execution_lease_locked(state_root)
        inspection = json.loads((case / "runtime.json").read_bytes())
        target_config = state_root / current["ownedRun"] / "config.env.target"
        if fault == "foreign":
            if inspection["Id"] == current["containerId"] or not target_config.is_file():
                raise SystemExit("foreign runtime fixture lost its exact scoped contradiction")
        elif (
            current["phase"] != "ROLLING_BACK" or target_config.exists()
            or inspection["Id"] != current["containerId"]
        ):
            raise SystemExit("missing target inputs fixture lost exact runtime ownership")
        evidence = json.dumps(dict(
            inspection=[inspection], backendInventory=[inspection["Id"]],
            composeInventory=[inspection["Id"]],
        )).encode()
        deadline = time.monotonic_ns() + 10_000_000_000

        def check() -> None:
            if time.monotonic_ns() >= deadline:
                raise SystemExit("bound refusal assertion exceeded its deadline")

        try:
            module._reconcile_recovery_lease_locked(
                state_root, lease, lease, current,
                (state_root / "timepad-recovery-authorization.json").read_bytes(),
                evidence, lock, check,
            )
        except module.GuardError as error:
            if error.reason != "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED":
                raise SystemExit("bound refusal reached the wrong helper gate")
        else:
            raise SystemExit("bound runtime/configuration contradiction passed reconciliation")
    if refusal_snapshot(case) != before:
        raise SystemExit("bound refusal changed incident/provider/lease/configuration/runtime")
    print(
        f"CONTROLLER_RECOVERY_HELPER_PASS: phase={current['phase']} fault={fault} "
        "reason=RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED writes=0"
    )


def assert_unknown_inventory_refusal(case: pathlib.Path) -> None:
    require_isolated(case)
    if (case / "fault").read_text() != "unknown-inventory":
        raise SystemExit("unknown inventory assertion requires its scoped fixture")
    assert_historical_request(case)
    before = refusal_snapshot(case)
    _, module = case_helpers(case)
    with module.deploy_lock(case / "state") as lock:
        _, current = module._read_guard_locked(case / "state")
        lease = module._read_execution_lease_locked(case / "state")
        values = []
        for arguments in (
            ["inspect", current["containerId"]],
            ["ps"], ["compose", "ps", "-aq", "backend"],
        ):
            result = subprocess.run(
                [sys.executable, "-B", __file__, "docker", *arguments],
                env=dict(os.environ, TIMEPAD_FIXTURE_CASE=str(case)),
                capture_output=True, timeout=5, check=False,
            )
            if result.returncode != 0 or result.stderr:
                raise SystemExit("unknown inventory fixture lost exact inspection or inventory")
            values.append(result.stdout)
        inspection = json.loads(values[0])
        inventories = [value.decode().splitlines() for value in values[1:]]
        if (
            current["phase"] != "COMMITTING" or current["commitSubstep"] != "provider-cleanup"
            or inspection[0]["Id"] != current["containerId"]
            or inventories != [["a" * 64], ["a" * 64]]
        ):
            raise SystemExit("unknown inventory did not isolate its foreign inventory contradiction")
        deadline = time.monotonic_ns() + 10_000_000_000

        def check() -> None:
            if time.monotonic_ns() >= deadline:
                raise SystemExit("unknown inventory assertion exceeded its deadline")

        try:
            module._reconcile_recovery_lease_locked(
                case / "state", lease, lease, current,
                (case / "state/timepad-recovery-authorization.json").read_bytes(),
                json.dumps(dict(
                    inspection=inspection, backendInventory=inventories[0],
                    composeInventory=inventories[1],
                )).encode(), lock, check,
            )
        except module.GuardError as error:
            if error.reason != "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED":
                raise SystemExit("unknown inventory reached the wrong private refusal")
        else:
            raise SystemExit("foreign inventory passed exact-runtime reconciliation")
    if refusal_snapshot(case) != before:
        raise SystemExit("unknown inventory refusal changed durable/runtime evidence")
    print(
        "CONTROLLER_RECOVERY_HELPER_PASS: phase=COMMITTING fault=unknown-inventory "
        "exact_inspect=1 reason=RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED writes=0"
    )


def refusal_snapshot(case: pathlib.Path) -> str:
    require_isolated(case)
    paths = [case / "runtime.json"]
    for root in (case / "state", case / "root", pathlib.Path("/var/lib/meet-production")):
        if root.exists():
            paths.extend([root, *root.rglob("*")])
    return json.dumps({
        str(path): identity(path).decode() if path.is_file() else None
        for path in sorted(paths)
    }, sort_keys=True)


def assert_foreign_provider_refusal(case: pathlib.Path) -> None:
    require_isolated(case)
    if (case / "fault").read_text() != "foreign-provider":
        raise SystemExit("foreign provider assertion requires its scoped fixture")
    before = refusal_snapshot(case)
    provider, module = case_helpers(case)
    state_root = case / "state"
    with module.deploy_lock(state_root) as lock:
        _, current = module._read_guard_locked(state_root)
        lease = module._read_execution_lease_locked(state_root)
        inspection = json.loads((case / "runtime.json").read_bytes())
        marker = json.loads((state_root / ".provider-transaction.current").read_bytes())
        if (
            current["phase"] != "CUTOVER_POSSIBLE"
            or lease is None or current["executionAttempt"] != lease["attempt"]
            or lease["lifecycle"] != "drained" or lease["worker"] is not None
            or inspection["Id"] != current["containerId"]
            or current["runtimeRequest"]["lifecycle"] != "completed"
            or marker["runKey"] != "foreign-provider-1"
            or marker["runKey"] == current["runId"]
        ):
            raise SystemExit("foreign provider fixture lost exact runtime/lease/request evidence")
        acknowledged = dict(current, runtimeRequest=dict(
            current["runtimeRequest"], lifecycle="acknowledged", completionDigest=None,
        ))
        proof = provider._runtime_request_proof(acknowledged, inspection)
        if proof["completionDigest"] != current["runtimeRequest"]["completionDigest"]:
            raise SystemExit("foreign provider fixture lost completed daemon request proof")
        evidence = json.dumps(dict(
            inspection=[inspection], backendInventory=[inspection["Id"]],
            composeInventory=[inspection["Id"]],
        )).encode()
        deadline = time.monotonic_ns() + 10_000_000_000

        def check() -> None:
            if time.monotonic_ns() >= deadline:
                raise SystemExit("foreign provider admission assertion exceeded its deadline")

        try:
            # Provider admission must refuse before successor-lease validation;
            # the historical lease is never permission to adopt or publish.
            module._reconcile_recovery_lease_locked(
                state_root, lease, lease, current,
                (state_root / "timepad-recovery-authorization.json").read_bytes(),
                evidence, lock, check,
            )
        except module.GuardError as error:
            if error.reason != "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED":
                raise SystemExit("foreign provider refused at the wrong helper gate")
        else:
            raise SystemExit("foreign provider unexpectedly passed reconciliation")
    if refusal_snapshot(case) != before:
        raise SystemExit("foreign provider helper refusal changed durable/runtime evidence")
    print("CONTROLLER_RECOVERY_HELPER_PASS: foreign-provider reason=RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED writes=0")


def assert_missing_refusal(case: pathlib.Path) -> None:
    require_isolated(case)
    fault = (case / "fault").read_text()
    if fault not in {"missing", "missing-request-proof"}:
        raise SystemExit("missing runtime assertion requires its scoped fixture")
    before = refusal_snapshot(case)
    provider, module = case_helpers(case)
    supervisor = load("missing_runtime_supervisor", SOURCE / "test_vps_timepad_supervisor.py")
    state_root = case / "state"
    with module.deploy_lock(state_root) as lock:
        _, current = module._read_guard_locked(state_root)
        lease = module._read_execution_lease_locked(state_root)
        if current["phase"] != "CUTOVER_POSSIBLE":
            raise SystemExit("missing runtime assertion requires cutover recovery")
        inspection = subprocess.run(
            [sys.executable, "-B", __file__, "docker", "inspect", current["containerId"]],
            env=dict(os.environ, TIMEPAD_FIXTURE_CASE=str(case)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False,
        )
        if inspection.returncode != 90 or inspection.stdout or inspection.stderr:
            raise SystemExit("missing runtime fixture unexpectedly supplied container inspection")
        if fault == "missing":
            if (
                current["runtimeRequest"] is not None
                or current["executionAttempt"] is not None or lease is not None
            ):
                raise SystemExit("missing legacy runtime fixture gained request/lease proof")
            attempt = supervisor.Attempt("forward-recover", nonce="6" * 32)
            attempt.arm()
            worker = supervisor.lease_identity(supervisor.process_identity(os.getpid()))
            candidate = historical_lease(
                module, attempt,
                owner=supervisor.lease_identity(supervisor.process_identity(os.getppid())),
                worker=worker,
                workers=[dict(mode="controller-worker", **worker)],
            )
            reason = "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"
            try:
                # Unleased legacy recovery cannot adopt without a completed
                # daemon request, before the later shell ownership gate.
                module.adopt_recovery_state(current, candidate)
            except module.GuardError as error:
                if error.reason != reason:
                    raise SystemExit("missing legacy runtime refused at the wrong helper gate")
            else:
                raise SystemExit("missing legacy runtime unexpectedly passed adoption")
        else:
            if (
                lease is None or current["executionAttempt"] != lease["attempt"]
                or lease["lifecycle"] != "drained" or lease["worker"] is not None
                or not lease["workers"]
                or not all(module._execution_process_exited(owner) for owner in (
                    lease["supervisor"], *lease["workers"],
                ))
                or current["runtimeRequest"] is None
                or current["runtimeRequest"]["lifecycle"] != "completed"
            ):
                raise SystemExit("missing runtime fixture lost historical request/lease proof")
            historical = json.loads((case / "runtime.json").read_bytes())
            acknowledged = dict(current, runtimeRequest=dict(
                current["runtimeRequest"], lifecycle="acknowledged", completionDigest=None,
            ))
            proof = provider._runtime_request_proof(acknowledged, historical)
            if proof["completionDigest"] != current["runtimeRequest"]["completionDigest"]:
                raise SystemExit("missing runtime fixture lost historical daemon completion")
            inventories = []
            for arguments in (["ps"], ["compose", "ps", "-aq", "backend"]):
                result = subprocess.run(
                    [sys.executable, "-B", __file__, "docker", *arguments],
                    env=dict(os.environ, TIMEPAD_FIXTURE_CASE=str(case)),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False,
                )
                if result.returncode != 0 or result.stderr:
                    raise SystemExit("missing runtime fixture inventory was unconfirmed")
                inventories.append(result.stdout.decode().splitlines())
            evidence = json.dumps(dict(
                inspection=[], backendInventory=inventories[0], composeInventory=inventories[1],
            )).encode()
            deadline = time.monotonic_ns() + 10_000_000_000

            def check() -> None:
                if time.monotonic_ns() >= deadline:
                    raise SystemExit("missing runtime reconciliation exceeded its deadline")

            reason = "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
            try:
                # Historical completion is not present runtime ownership.
                # Refuse before successor validation or either durable write.
                module._reconcile_recovery_lease_locked(
                    state_root, lease, lease, current,
                    (state_root / "timepad-recovery-authorization.json").read_bytes(),
                    evidence, lock, check,
                )
            except module.GuardError as error:
                if error.reason != reason:
                    raise SystemExit("missing runtime refused at the wrong reconciliation gate")
            else:
                raise SystemExit("missing runtime unexpectedly passed reconciliation")
    if refusal_snapshot(case) != before:
        raise SystemExit("missing runtime helper refusal changed durable/runtime evidence")
    label = "missing-legacy" if fault == "missing" else fault
    print(f"CONTROLLER_RECOVERY_HELPER_PASS: {label} reason={reason} inspect_status=90 writes=0")


def unresolved_registration_snapshot(case: pathlib.Path) -> str:
    """Validate the legacy refusal's control-plane residue, not quiescence."""
    require_isolated(case)
    fault = (case / "fault").read_text()
    if fault not in {"missing", "active-child", "active-child-missing-input"}:
        raise SystemExit("unresolved registration requires its scoped legacy refusal")
    fixtures = load("unresolved_registration_fixtures", SOURCE / "test-test-vps-provider-credential.py")
    module = fixtures.helper._timepad_state_module()
    state_root = case / "state"
    with module.deploy_lock(state_root):
        _, current = module._read_guard_locked(state_root)
        lease = module._read_execution_lease_locked(state_root)
        if (
            current["phase"] not in {"CUTOVER_POSSIBLE", "ROLLING_BACK"}
            or current["runtimeRequest"] is not None or current["executionAttempt"] is not None
            or lease is None or lease["operation"] != "forward-recover"
            or lease["lifecycle"] != "draining" or lease["firstFailure"] != "EXIT"
            or lease["firstStatus"] != 1 or lease["rollbackIssued"]
            or lease["workerMode"] != "fail-closed-worker"
            or [worker["mode"] for worker in lease["workers"]] != [
                "controller-worker", "fail-closed-worker",
            ]
            or lease["worker"] != {
                key: lease["workers"][-1][key] for key in ("pid", "bootId", "startTicks")
            }
            or lease["workEndNs"] - lease["t0Ns"] != 540_000_000_000
            or lease["hardEndNs"] - lease["workEndNs"] != 60_000_000_000
            or not all(module._execution_process_exited(worker) for worker in lease["workers"])
        ):
            raise SystemExit("legacy refusal lost its exact unresolved execution evidence")
        owner = lease["supervisor"]
        record = module._execution_process_record(owner)
        if record is not None and record[:2] == (owner["bootId"], owner["startTicks"]):
            process = pathlib.Path(f"/proc/{owner['pid']}")
            fields = (process / "stat").read_bytes().rsplit(b")", 1)[1].split()
            if (
                fields[0] != b"Z" or int(fields[19]) != owner["startTicks"]
                or (process / f"task/{owner['pid']}/children").read_bytes().split()
                or list((process / "fd").iterdir())
            ):
                raise SystemExit("unresolved registration still has an unproved live owner/writer")
        # A zombie retains its /proc identity, but no file descriptors or
        # children. The unresolved lease, not a claimed live lock-keeper,
        # excludes replay after this attempt's writers have exited.
        snapshot = json.loads(refusal_snapshot(case))
        del snapshot[str(state_root / module.EXECUTION_LEASE_NAME)]
        return json.dumps(snapshot, sort_keys=True)


def run_active(case: pathlib.Path, command: list[str]) -> int:
    require_isolated(case)
    fixtures = load("active_recovery_fixtures", SOURCE / "test-test-vps-provider-credential.py")
    module = fixtures.helper._timepad_state_module()
    root = case / "state"
    _, current = module.read_guard(root)
    child = subprocess.Popen(
        [sys.executable, "-B", "-c", "import sys; sys.stdin.buffer.read()"],
        stdin=subprocess.PIPE, start_new_session=True,
    )
    waiter = None
    try:
        with module.deploy_lock(root) as lock:
            # The fixture publishes through the same inherited-lock validation
            # used by the controller's fixed worker handoff.
            os.set_inheritable(lock, True)
            record = module.capture_owned_child(
                child.pid, command_digest="1" * 64,
                attempt_id=current["incidentId"] + ":1",
            )
            current = module.advance_state(
                current, current["phase"], ownedChild=record,
                latestAttemptId=record["attemptId"],
            )
            module.publish_current(root, current, deploy_lock_fd=lock)
            current = module.advance_state(
                current, current["phase"], ownedChild=dict(record, lifecycle="released"),
            )
            module.publish_current(root, current, deploy_lock_fd=lock)
        # Only fixture teardown may stop/reap this deliberately unproved child;
        # its continued liveness is part of the recovery-refusal assertion.
        waiter = threading.Thread(target=child.wait, daemon=True)
        waiter.start()
        private(case / "active-before", (root / "timepad-guard/current.json").read_bytes())
        before = refusal_snapshot(case)
        result = subprocess.run(command, timeout=120, check=False)
        # This deliberately malformed historical snapshot has neither a
        # request-before-release record nor an execution lease. Refusal must
        # preserve the live child; only fixture teardown may terminate it.
        if child.poll() is not None or not module.owned_child_is_same_process(record):
            raise SystemExit("unproved recovery signaled the fixture-owned child")
        if (case / "active-before").read_bytes() != (
            root / "timepad-guard/current.json"
        ).read_bytes():
            raise SystemExit("unproved recovery changed durable owned-child state")
        if unresolved_registration_snapshot(case) != before:
            raise SystemExit("unproved recovery changed incident/provider/configuration/runtime")
        return result.returncode
    finally:
        if child.poll() is None:
            child.kill()
        if child.stdin is not None:
            child.stdin.close()
        if waiter is not None:
            waiter.join(timeout=5)
            if waiter.is_alive():
                raise SystemExit("fixture child reap was unconfirmed")
        else:
            child.wait(timeout=5)


def docker(case: pathlib.Path, arguments: list[str]) -> None:
    path = case / "runtime.json"
    observed = json.loads(path.read_bytes())
    image = observed["Image"]
    labels = observed["Config"]["Labels"]
    op = arguments[0]
    fault = (case / "fault").read_text()
    replacement = fault in {"replace", "create-fails", "create-intent"}
    exists = not replacement or (case / "created").exists()
    if op == "image" and arguments[1] == "inspect":
        if "--format" not in arguments:
            print(json.dumps([dict(observed, Id=image)]))
            return
    elif op == "ps":
        if fault == "unknown-inventory":
            print("a" * 64)
        elif exists:
            print(observed["Id"])
        return
    elif op == "compose" and "config" in arguments:
        print(json.dumps(dict(services=dict(backend=dict(
            image="ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64,
            environment={}, volumes=[],
        )))))
        return
    elif op == "compose" and "up" in arguments:
        if fault == "create-fails":
            raise SystemExit(90)
        if not replacement or exists or "--no-start" not in arguments:
            raise SystemExit("unapproved fixture creation")
        observed["Id"] = "b" * 64
        with path.open("w") as stream:
            json.dump(observed, stream)
        private(case / "created", b"")
        return
    elif op == "compose" and "ps" in arguments:
        if arguments[-1] not in {"backend", "postgres"}:
            raise SystemExit(90)
        if arguments[-1] == "postgres":
            print("e" * 64)
        elif fault == "unknown-inventory":
            print("a" * 64)
        elif exists:
            print(observed["Id"])
        return
    elif op == "inspect":
        if fault in {"missing", "missing-request-proof"} or not exists or arguments[1] != observed["Id"]:
            raise SystemExit(90)
        if "--format" not in arguments:
            print(json.dumps([observed]))
            return
    elif op in {"start", "stop", "update"}:
        if arguments[-1] != observed["Id"]:
            raise SystemExit("refused foreign runtime mutation")
        if op == "start":
            if fault == "reaped-child" and (case / "historical-before").exists():
                fixtures = load("retry_child_fixtures", SOURCE / "test-test-vps-provider-credential.py")
                module = fixtures.helper._timepad_state_module()
                before = json.loads((case / "historical-before").read_bytes())
                # Only the later retry is logged by the Docker shell adapter.
                with module.deploy_lock(case / "state", 9):
                    _, current = module._read_guard_locked(case / "state")
                    lease = module._read_execution_lease_locked(case / "state")
                    child, request = current["ownedChild"], current["runtimeRequest"]
                    if (
                        current["phase"] != "FORWARD_RECOVERING"
                        or current["operationEpoch"] != before["operationEpoch"]
                        or current["incidentId"] != before["incidentId"]
                        or current["executionAttempt"] == before["executionAttempt"]
                        or lease is None or current["executionAttempt"] != lease["attempt"]
                        or child is None or child["lifecycle"] != "released"
                        or child["attemptId"] != current["incidentId"] + ":2"
                        or request is None or request["operation"] != "start"
                        or request["lifecycle"] != "intent" or request["sequence"] != 3
                        or request["childAttemptId"] != child["attemptId"]
                        or request["executionAttempt"] != lease["attempt"]
                        or observed["State"]["Running"]
                        or observed["HostConfig"]["RestartPolicy"]["Name"] != "no"
                    ):
                        raise SystemExit("retry started before clearing historical child ownership")
                    module.require_child_group_quiescent(before["ownedChild"])
                private(case / "cleared-before-retry", b"")
            observed["State"]["Running"] = True
            observed["State"]["Health"]["Status"] = "healthy"
        elif op == "stop":
            observed["State"]["Running"] = False
        elif arguments[1] == "--restart=no":
            observed["HostConfig"]["RestartPolicy"]["Name"] = "no"
        else:
            raise SystemExit(90)
        with path.open("w") as stream:
            json.dump(observed, stream)
        print(observed["Id"])
        return
    else:
        raise SystemExit(90)
    form = arguments[arguments.index("--format") + 1]
    values = {
        "{{.Id}}": image if op == "image" else observed["Id"],
        "{{.Image}}": image,
        "{{.Config.User}}": "10001:10001",
        "{{.State.Running}}": str(observed["State"]["Running"]).lower(),
        "{{.HostConfig.RestartPolicy.Name}}": observed["HostConfig"]["RestartPolicy"]["Name"],
        "{{.State.Health.Status}}": observed["State"]["Health"]["Status"],
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}": observed["State"]["Health"]["Status"],
        # Deliberate real-verifier failure after the retry, not a fake verifier.
        "{{.HostConfig.ReadonlyRootfs}}": "false",
    }
    for key, value in labels.items():
        values['{{index .Config.Labels "' + key + '"}}'] = value
    if form not in values:
        raise SystemExit(90)
    print(values[form])


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        if sys.argv[5:] not in ([], ["legacy"], ["request-proof"]):
            raise SystemExit("unknown recovery fixture proof mode")
        setup(
            pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4],
            request_proof=sys.argv[5:] == ["request-proof"],
        )
    elif sys.argv[1] == "docker":
        docker(pathlib.Path(os.environ["TIMEPAD_FIXTURE_CASE"]), sys.argv[2:])
    elif sys.argv[1] == "run-controller":
        case = pathlib.Path(sys.argv[2])
        require_isolated(case)
        if pathlib.Path(__file__).resolve() != case / "tools/recovery.py":
            raise SystemExit("recovery controller must use its staged fixture")
        channel = load("historical_controller_channel", case / "tools/create-controller.py")
        raise SystemExit(channel.recover(case, sys.argv[3:]))
    elif sys.argv[1] == "refusal-snapshot":
        print(refusal_snapshot(pathlib.Path(sys.argv[2])))
    elif sys.argv[1] == "assert-foreign-provider":
        assert_foreign_provider_refusal(pathlib.Path(sys.argv[2]))
    elif sys.argv[1] == "assert-missing":
        assert_missing_refusal(pathlib.Path(sys.argv[2]))
    elif sys.argv[1] == "assert-historical-request":
        assert_historical_request(pathlib.Path(sys.argv[2]))
    elif sys.argv[1] == "assert-bound-refusal":
        assert_bound_refusal(pathlib.Path(sys.argv[2]))
    elif sys.argv[1] == "assert-unknown-inventory":
        assert_unknown_inventory_refusal(pathlib.Path(sys.argv[2]))
    elif sys.argv[1] == "unresolved-registration-snapshot":
        print(unresolved_registration_snapshot(pathlib.Path(sys.argv[2])))
    elif sys.argv[1] == "run-active":
        raise SystemExit(run_active(pathlib.Path(sys.argv[2]), sys.argv[3:]))
    elif sys.argv[1] == "lose-replacement":
        case = pathlib.Path(sys.argv[2])
        require_isolated(case)
        if json.loads((case / "runtime.json").read_bytes())["Id"] != "b" * 64:
            raise SystemExit("fixture has no bound replacement to lose")
        (case / "created").unlink()
    else:
        raise SystemExit(90)
