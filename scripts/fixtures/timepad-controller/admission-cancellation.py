#!/usr/bin/env python3
"""Isolated bootstrap/lost-state and forward-recovery cancellation assertions."""

from __future__ import annotations

import json
import os
import pathlib
import select
import shutil
import signal
import subprocess
import sys
import time

import recovery


BASE = pathlib.Path("/var/lib/timepad-fixture/case-admission")
CONTROLLER = recovery.SOURCE / "deploy-test-vps-provider-release.sh"
AUTHORITY = dict(
    rootId="test-root", bootstrapId="fixture-bootstrap",
    initialRuntime="a" * 64, initialConfig="b" * 64,
    initialSchema="c" * 64, initialStartupInventory="d" * 64,
    schemaHistoryProvenance=True,
)
OBSERVED = dict(
    rootId="test-root", runtime="a" * 64, config="b" * 64,
    schema="c" * 64, startupInventory="d" * 64, schemaHistoryProvenance=True,
)


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise SystemExit("ASSERTION_FAIL: " + reason)


def no_starts(case: pathlib.Path) -> None:
    log = case / "docker.log"
    lines = log.read_text().splitlines() if log.exists() else []
    require(len(lines) <= 512, "fixture Docker trace exceeded its bound")
    require(not any(
        line.startswith(("start:", "start-id:", "compose:start", "compose:up"))
        for line in lines
    ), "cancelled/refused case attempted a target or predecessor start")


def no_runtime_mutations(case: pathlib.Path) -> None:
    no_starts(case)
    log = case / "docker.log"
    lines = log.read_text().splitlines() if log.exists() else []
    require(not any(
        line.startswith(("update:", "stop:", "rm:", "compose:create", "compose:stop", "compose:rm"))
        for line in lines
    ), "read-only admission acquired runtime mutation authority")


def environment(case: pathlib.Path) -> dict[str, str]:
    source = recovery.SOURCE / "fixtures/timepad-controller"
    runtime_bin = case / "bin"
    if not runtime_bin.exists():
        runtime_bin.mkdir(mode=0o700)
        for name in ("docker", "curl"):
            shutil.copyfile(source / name, runtime_bin / name)
            (runtime_bin / name).chmod(0o700)
    return dict(
        os.environ, TEST_VPS_STATE_ROOT=str(case / "state"),
        TIMEPAD_FIXTURE_DOCKER_LOG=str(case / "docker.log"),
        TIMEPAD_FIXTURE_CASE=str(case), PYTHONDONTWRITEBYTECODE="1",
        TIMEPAD_FIXTURE_CURL_LOG=str(case / "curl.log"), DOCKER_HOST="",
        TIMEPAD_FIXTURE_ADAPTER_DIR=str(source),
        PATH=str(runtime_bin) +
        ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    )


def bootstrap_command(case: pathlib.Path) -> list[str]:
    return [
        "bash", str(CONTROLLER),
        "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
        "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "0" * 64,
        "--revision", "0" * 40, "--version", "1.4.0",
        "--run-key", "fixture-bootstrap-dispatch", "--mode", "deploy",
        "--operation", "bootstrap-guard", "--initial-proof-id", "fixture-proof",
        "--bootstrap-id", AUTHORITY["bootstrapId"],
    ]


def execute(case: pathlib.Path, command: list[str]) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            ["timeout", "--kill-after=5s", "45s", *command],
            env=environment(case), capture_output=True, timeout=55, check=False,
        )
    finally:
        no_starts(case)
    require(result.returncode not in {124, 137}, "fixture subprocess exceeded its deadline")
    require(len(result.stdout) + len(result.stderr) <= 65536, "fixture output exceeded its bound")
    return result


def helper_command(case: pathlib.Path, operation: str) -> list[str]:
    command = [
        sys.executable, "-B", str(recovery.SOURCE / "test_vps_timepad_state.py"),
        operation, "--root", str(case / "state"),
    ]
    if operation == "bootstrap":
        command += [
            "--authority", str(case / "state/timepad-bootstrap-authority.json"),
            "--observed", str(case / "state/timepad-bootstrap-observed.json"),
        ]
    return command


def inputs(case: pathlib.Path) -> None:
    recovery.private(
        case / "state/timepad-bootstrap-authority.json", json.dumps(AUTHORITY).encode(),
    )
    recovery.private(
        case / "state/timepad-bootstrap-observed.json", json.dumps(OBSERVED).encode(),
    )


def fresh(case: pathlib.Path) -> None:
    recovery.require_isolated(case)
    for directory in (case, case / "root", case / "state"):
        directory.mkdir(mode=0o700)
    inputs(case)
    for target, source in (
        (case / "root/.env.production", "root-env"),
        (case / "root/docker-compose.production.yml", "compose.yml"),
        (case / "compose.yml", "compose.yml"),
    ):
        recovery.private(target, (recovery.SOURCE / "fixtures/timepad-controller" / source).read_bytes())


def snapshot(case: pathlib.Path) -> dict[str, bytes]:
    guard = case / "state/timepad-guard"
    return {path.name: path.read_bytes() for path in guard.iterdir()} if guard.exists() else {}


def helper_bootstrap(case: pathlib.Path, outcome: str) -> None:
    result = execute(case, helper_command(case, "bootstrap"))
    require(result.returncode == 0, "explicit helper bootstrap failed")
    document = json.loads(result.stdout)
    require(document["outcome"] == outcome and document["epoch"] == 0,
            "bootstrap did not preserve the initial epoch/outcome")
    guard = snapshot(case)
    require(set(guard) == {"origin.json", "current.json"}, "bootstrap guard inventory is not exact")
    origin, current = (json.loads(guard[name]) for name in ("origin.json", "current.json"))
    require(current["phase"] == "READY" and current["operationEpoch"] == 0 and
            current["originDigest"] == origin["originDigest"] == document["originDigest"],
            "bootstrap did not publish a bound initial READY state")


def bootstrap_cases() -> None:
    case = BASE.with_name(BASE.name + "-initial")
    fresh(case)
    helper_bootstrap(case, "bootstrapped")
    before = snapshot(case)
    helper_bootstrap(case, "already-initialized")
    require(snapshot(case) == before, "initial replay changed durable guard bytes")
    print("CONTROLLER_BOOTSTRAP_HELPER_PASS: explicit initial publication and idempotent replay", flush=True)

    for phase in ("READY", "CUTOVER_POSSIBLE", "ROLLED_BACK"):
        case = BASE.with_name(BASE.name + "-lost-" + phase.lower())
        if phase == "READY":
            fresh(case)
            helper_bootstrap(case, "bootstrapped")
        else:
            recovery.setup(
                case, "ROLLING_BACK" if phase == "ROLLED_BACK" else phase,
                "intact", compatible=phase == "ROLLED_BACK",
            )
            inputs(case)
            if phase == "ROLLED_BACK":
                module = recovery.load("lost_state_helper", recovery.SOURCE / "test_vps_timepad_state.py")
                _, current = module.read_guard(case / "state")
                module.publish_current(
                    case / "state",
                    module.advance_state(current, "ROLLED_BACK", terminalReceipt="7" * 64),
                )
            before = snapshot(case)
            result = execute(case, helper_command(case, "bootstrap"))
            require(result.returncode != 0 and b"BOOTSTRAP_NOT_INITIAL" in result.stderr,
                    "bootstrap reset an existing transition/rollback epoch")
            require(snapshot(case) == before, "unauthorized reset changed durable state")
        (case / "state/timepad-guard/current.json").unlink()
        before = snapshot(case)
        for operation in ("read-state", "bootstrap"):
            result = execute(case, helper_command(case, operation))
            require(result.returncode != 0 and b"GUARD_STATE_LOST" in result.stderr,
                    "lost current state was not refused by " + operation)
            require(snapshot(case) == before, "lost-state refusal recreated or changed guard state")
        print("CONTROLLER_BOOTSTRAP_HELPER_PASS: lost-current phase=" + phase, flush=True)

    case = BASE.with_name(BASE.name + "-staging")
    fresh(case)
    (case / "state/.timepad-bootstrap-conflicting").mkdir(mode=0o700)
    result = execute(case, helper_command(case, "bootstrap"))
    require(result.returncode != 0 and b"BOOTSTRAP_STAGING_CONFLICT" in result.stderr,
            "conflicting initialization staging was not refused")
    require(not snapshot(case), "staging refusal published a guard")
    print("CONTROLLER_BOOTSTRAP_HELPER_PASS: conflicting staging", flush=True)

    case = BASE.with_name(BASE.name + "-controller")
    fresh(case)
    result = execute(case, bootstrap_command(case))
    require(result.returncode == 0, "controller bootstrap lacks successful supervised completion")
    before = snapshot(case)
    require(set(before) == {"origin.json", "current.json"}, "controller bootstrap did not publish guard")
    result = execute(case, bootstrap_command(case))
    require(result.returncode == 0 and snapshot(case) == before,
            "controller bootstrap replay failed or mutated guard")
    (case / "state/timepad-guard/current.json").unlink()
    before = snapshot(case)
    result = execute(case, bootstrap_command(case))
    require(result.returncode != 0 and snapshot(case) == before,
            "controller reset lost guard state")
    print("CONTROLLER_BOOTSTRAP_PASS: explicit bootstrap, replay and lost-state refusal", flush=True)


def checkpoint(case: pathlib.Path) -> None:
    recovery.require_isolated(case)
    # One-shot admission checkpoint; cleanup inspections must never wait here.
    try:
        recovery.private(case / "checkpoint-used", b"")
    except FileExistsError:
        return
    ready = os.open(case / "ready", os.O_WRONLY | os.O_NONBLOCK)
    release = os.open(case / "release", os.O_RDWR | os.O_NONBLOCK)
    try:
        os.write(ready, b"admission\n")
        require(bool(select.select([release], [], [], 35)[0]), "checkpoint was not cancelled or released")
        require(os.read(release, 32) == b"exit\n", "invalid checkpoint release")
        raise SystemExit(90)
    finally:
        os.close(ready)
        os.close(release)


def cancellation_case(name: str) -> None:
    case = BASE.with_name(BASE.name + "-cancel-" + name.lower())
    recovery.setup(case, "CUTOVER_POSSIBLE", "intact", compatible=False)
    before = snapshot(case)
    runtime_before = (case / "runtime.json").read_bytes()
    current = json.loads(before["current.json"])
    require(current["predecessorDisposition"] == "pre-barrier-only", "fixture predecessor is not incompatible")
    for fifo in ("ready", "release"):
        os.mkfifo(case / fifo, 0o600)
    ready = os.open(case / "ready", os.O_RDWR | os.O_NONBLOCK)
    env = environment(case)
    env["TIMEPAD_FIXTURE_CANCEL_AT"] = "image:inspect"
    command = [
        "bash", str(case / "tools/deploy-test-vps-provider-release.sh"),
        "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
        "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64,
        "--revision", "3" * 40, "--version", "1.2.3",
        "--run-key", "fixture-cancel-dispatch", "--mode", "deploy",
        "--operation", "forward-recover", "--recovery-run-key", current["runId"],
        "--recovery-incident", current["incidentId"], "--recovery-epoch", "1",
        "--recovery-binding-digest", current["evidenceDigest"],
        "--recovery-action", "retry-exact-candidate",
    ]
    process = subprocess.Popen(
        command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    try:
        require(bool(select.select([ready], [], [], 25)[0]),
                "controller did not reach recovery admission checkpoint; supervisor integration is required")
        require(os.read(ready, 32) == b"admission\n", "unexpected checkpoint")
        lease_path = case / "state/.timepad-execution.json"
        lease = json.loads(lease_path.read_bytes())
        require(lease["operation"] == "forward-recover" and not lease["rollbackIssued"],
                "recovery had predecessor rollback authority before cancellation")
        require(lease["workEndNs"] - time.monotonic_ns() > 400_000_000_000,
                "cancellation fixture lacks substantial remaining work")
        if name == "EXIT":
            release = os.open(case / "release", os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.write(release, b"exit\n")
            finally:
                os.close(release)
        else:
            process.send_signal(getattr(signal, "SIG" + name))
        output, error = process.communicate(timeout=45)
        require(len(output) + len(error) <= 65536, "cancellation output exceeded its bound")
        require(process.returncode == (1 if name == "EXIT" else 128 + getattr(signal, "SIG" + name)),
                "controller did not retain initiating cancellation status")
        terminal = json.loads(lease_path.read_bytes())
        require(terminal["firstFailure"] == name and terminal["firstStatus"] == process.returncode,
                "durable lease lost initiating cancellation")
        require(all(terminal[key] == lease[key] for key in ("attempt", "t0Ns", "workEndNs", "hardEndNs")),
                "cancellation reset the attempt or deadline")
        require(not terminal["rollbackIssued"] and
                all(worker["mode"] != "rollback-worker" for worker in terminal["workers"]),
                "forward recovery received predecessor rollback authority")
        require(b"schema_guard=QUIESCENCE_UNCONFIRMED" in output and
                terminal["lifecycle"] in {"draining", "quiescence-unconfirmed"} and
                terminal["worker"] is not None,
                "read-only cancellation fabricated successful runtime/childless completion")
        for worker in terminal["workers"]:
            process_stat = pathlib.Path(f'/proc/{worker["pid"]}/stat')
            try:
                fields = process_stat.read_bytes().rsplit(b")", 1)[1].split()
            except FileNotFoundError:
                continue
            require(int(fields[19]) != worker["startTicks"], "cancelled controller worker survived drain")
        require(snapshot(case) == before, "cancelled read-only admission changed the incident")
        require((case / "runtime.json").read_bytes() == runtime_before,
                "unadopted incident gained runtime stop/update authority")
        no_runtime_mutations(case)
        # Kernel drain and the relay's nonzero result do not authorize adoption
        # of an old incident or replacement of its unresolved lease. Exact
        # selectors still have to refuse on a subsequent invocation.
        lease_before = lease_path.read_bytes()
        retry = execute(case, command)
        require(retry.returncode != 0 and b"QUIESCENCE_UNCONFIRMED" in retry.stdout,
                "unresolved cancellation lease allowed recovery replay")
        require(lease_path.read_bytes() == lease_before and snapshot(case) == before and
                (case / "runtime.json").read_bytes() == runtime_before,
                "recovery replay replaced unresolved lease/state/runtime")
        no_runtime_mutations(case)
        print("CONTROLLER_CANCELLATION_PASS: forward-recover fault=" + name +
              " target_starts=0 predecessor_starts=0", flush=True)
    finally:
        try:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
        finally:
            os.close(ready)
            no_runtime_mutations(case)


if __name__ == "__main__":
    recovery.require_isolated(BASE)
    BASE.parent.mkdir(mode=0o700, exist_ok=True)
    if sys.argv[1:] == ["bootstrap"]:
        bootstrap_cases()
    elif sys.argv[1:] == ["cancellation"]:
        for fault in ("TERM", "INT", "HUP", "EXIT"):
            cancellation_case(fault)
    elif len(sys.argv) == 3 and sys.argv[1] == "checkpoint":
        checkpoint(pathlib.Path(sys.argv[2]))
    else:
        raise SystemExit(2)
