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


SOURCE = pathlib.Path(__file__).resolve().parents[2]


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


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


def setup(case: pathlib.Path, phase: str, fault: str) -> None:
    require_isolated(case)
    fixtures = load("provider_recovery_fixtures", SOURCE / "test-test-vps-provider-credential.py")
    module, contract, _, template, envelope = fixtures.live_context(phase)
    root, state_root, tools = (case / name for name in ("root", "state", "tools"))
    for directory in (case, root, state_root, tools):
        directory.mkdir(mode=0o700)
    for name in (
        "deploy-test-vps-provider-release.sh", "production-compose.sh",
        "update-production-release.sh", "test-vps-runtime-invariants.sh",
        "test-vps-provider-credential.py", "test_vps_timepad_state.py",
    ):
        shutil.copy2(SOURCE / name, tools / name)
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
    )
    module.publish_current(state_root, current)
    if phase != "PREPARED":
        current = module.advance_state(
            current, "CUTOVER_POSSIBLE", containerId=template["containerId"],
            configHash=template["configHash"],
        )
        module.publish_current(state_root, current)
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
    auth = dict(envelope["authorization"], originDigest=origin["originDigest"])
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
        private(run / "target-runtime.override.yml", b"services:\n  backend: {}\n")
        if fault == "create-intent":
            current = module.advance_state(current, "FORWARD_RECOVERING")
            current = module.advance_state(
                current, "FORWARD_RECOVERING", commitSubstep="replacement-create-intent",
            )
            module.publish_current(state_root, current)
    inspection["State"]["Running"] = False
    inspection["State"]["Health"]["Status"] = "starting"
    if fault == "foreign":
        inspection["Id"] = "a" * 64
    private(case / "runtime.json", json.dumps(inspection).encode())
    private(case / "fault", fault.encode())
    private(case / "binding", current["evidenceDigest"].encode())
    if fault in {"missing-input", "active-child-missing-input"}:
        (run / "config.env.target").unlink()


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
        # Reap concurrently: the recovered controller is not the crashed
        # child's parent. A group containing even a zombie cannot be cleared.
        waiter = threading.Thread(target=child.wait, daemon=True)
        waiter.start()
        private(case / "active-before", (root / "timepad-guard/current.json").read_bytes())
        result = subprocess.run(command, timeout=120, check=False)
        if (case / "fault").read_text() == "active-child-missing-input":
            if child.poll() is not None:
                raise SystemExit("invalid provider proof signaled owned child")
            if (case / "active-before").read_bytes() != (
                root / "timepad-guard/current.json"
            ).read_bytes():
                raise SystemExit("invalid provider proof changed owned child state")
        elif child.poll() is None:
            raise SystemExit("recovery did not quiesce owned child")
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
    replacement = fault in {"replace", "create-fails", "unknown-inventory", "create-intent"}
    exists = not replacement or (case / "created").exists()
    if op == "image" and arguments[1] == "inspect":
        if "--format" not in arguments:
            print(json.dumps([dict(observed, Id=image)]))
            return
    elif op == "ps":
        if exists:
            print(observed["Id"])
        elif fault == "unknown-inventory":
            print("a" * 64)
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
        elif exists:
            print(observed["Id"])
        elif fault == "unknown-inventory":
            print("a" * 64)
        return
    elif op == "inspect":
        if fault == "missing" or not exists or arguments[1] != observed["Id"]:
            raise SystemExit(90)
        if "--format" not in arguments:
            print(json.dumps([observed]))
            return
    elif op in {"start", "stop", "update"}:
        if arguments[-1] != observed["Id"]:
            raise SystemExit("refused foreign runtime mutation")
        if op == "start":
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
        setup(pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif sys.argv[1] == "docker":
        docker(pathlib.Path(os.environ["TIMEPAD_FIXTURE_CASE"]), sys.argv[2:])
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
