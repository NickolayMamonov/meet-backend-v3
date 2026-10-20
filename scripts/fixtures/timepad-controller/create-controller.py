#!/usr/bin/env python3
"""Actual-worker channel and initial guarded-create fixtures.

Only the explicit Supervisor constructor receives the fixture transport. The
production worker, state/provider helpers, locks, grants and terminal publisher
are unchanged. Observations below are fixture-only snapshots of actual writes,
never replacement state, wait evidence or publication acknowledgments. Passing
the initial-create row does not prove the complete controller acceptance matrix.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import re
import sys
import time
import traceback


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise AssertionError(reason)


def no_socket() -> None:
    require(not os.environ.get("DOCKER_HOST"), "fixture Docker host is not empty")
    require(not any(os.path.lexists(path) for path in (
        "/run/docker.sock", "/var/run/docker.sock",
    )), "fixture can see a Docker socket")


def isolated(case: Path) -> None:
    require(sys.platform == "linux" and os.geteuid() == 0, "isolated Linux/root is required")
    require(case.is_absolute() and case.parent == Path("/var/lib/timepad-fixture") and
            case.name.startswith("case-create-worker-"), "fixture case path is not fixed")
    for name, kind in (("mnt", "MOUNT"), ("net", "NETWORK"), ("pid", "PID")):
        parent = os.environ.get("TIMEPAD_FIXTURE_PARENT_" + kind + "_NS")
        require(parent is not None and parent != os.readlink("/proc/self/ns/" + name),
                "fixture namespace isolation is unproved")
    mounts = Path("/proc/self/mountinfo").read_text().splitlines()
    require(any(
        line.split()[4] == "/var/lib" and " - tmpfs " in line and
        not any(field.startswith(("shared:", "master:")) for field in line.split())
        for line in mounts
    ), "fixture private /var/lib is unproved")
    no_socket()


def private(path: Path, value: bytes) -> None:
    with path.open("xb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(value)


def prepare(case: Path, scenario: str) -> None:
    source = Path(__file__).resolve().parents[2]
    case.parent.mkdir(mode=0o700, exist_ok=True)
    case.mkdir(mode=0o700, exist_ok=True)
    require(not any(case.iterdir()) and not case.is_symlink(), "fixture case is not fresh")
    for name in ("tools", "root", "state"):
        (case / name).mkdir(mode=0o700)
    for name in (
        "deploy-test-vps-provider-release.sh", "production-compose.sh",
        "update-production-release.sh", "test-vps-runtime-invariants.sh",
        "production-config-digest.sh",
        "test-vps-provider-credential.py", "test_vps_timepad_state.py",
        "test_vps_timepad_supervisor.py", "test_vps_timepad_create.py",
        "test-vps-timepad-release-contracts.json",
    ):
        shutil.copyfile(source / name, case / "tools" / name)
        (case / "tools" / name).chmod(0o700 if name.endswith(".sh") else 0o600)
    shutil.copyfile(Path(__file__), case / "tools/create-controller.py")
    forward = scenario not in {"bootstrap", "bootstrap-mismatch", "deploy-blocked"}
    if forward:
        import forward as external

        active_root = Path("/var/lib/meet-production")
        active_root.mkdir(mode=0o700, exist_ok=True)
        require(not any(active_root.iterdir()), "forward fixture active root is not fresh")
        facts = external.fixture_data(source)
        shutil.copyfile(Path(__file__).with_name("forward.py"), case / "tools/forward.py")
        (case / "bin").mkdir(mode=0o700)
        for kind in ("docker", "curl"):
            shutil.copyfile(Path(__file__).with_name("forward-" + kind), case / "bin" / kind)
            (case / "bin" / kind).chmod(0o700)
        (case / "bin/docker").write_bytes(
            b'#!/usr/bin/env bash\nset -euo pipefail\n'
            b': "${TIMEPAD_FIXTURE_CASE:?forward fixture case is required}"\n'
            b'exec python3 -B "$TIMEPAD_FIXTURE_CASE/tools/create-controller.py" '
            b'--external-docker "$@"\n'
        )
        private(case / "forward-facts.json", json.dumps(facts).encode())
        backend = next(item for item in facts["resources"]["containerInspections"]
                       if item["Config"]["Labels"]["com.docker.compose.service"] == "backend")
        private(case / "forward-runtime.json", json.dumps({"backend": backend, "created": False}).encode())
        private(case / "forward-scenario", scenario.encode())
        contract_path = case / "tools/test-vps-timepad-release-contracts.json"
        contract_path.write_bytes(json.dumps(facts["contract"]).encode())
    for name, fixture in (
        ("root/.env.production", "root-env"),
        ("root/docker-compose.production.yml", "compose.yml"),
        ("compose.yml", "compose.yml"),
    ):
        private(case / name, (source / "fixtures/timepad-controller" / fixture).read_bytes())
    if forward:
        (case / "root/.env.production").write_text("\n".join(backend["Config"]["Env"]) + "\n")
    authority = {
        "rootId": "test-root", "bootstrapId": "fixture-bootstrap",
        "initialRuntime": "a" * 64, "initialConfig": "b" * 64,
        "initialSchema": "c" * 64, "initialStartupInventory": "d" * 64,
        "schemaHistoryProvenance": True,
    }
    observed = {
        "rootId": "test-root", "runtime": "a" * 64, "config": "b" * 64,
        "schema": "c" * 64, "startupInventory": "d" * 64,
        "schemaHistoryProvenance": True,
    }
    if scenario == "bootstrap-mismatch":
        observed["runtime"] = "f" * 64
    for name, value in (("authority", authority), ("observed", observed)):
        private(case / ("state/timepad-bootstrap-" + name + ".json"),
                json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


@dataclass(frozen=True)
class RefusingTransport:
    """No evidence is needed before these gates; any request is a test failure."""

    case: Path

    def _unexpected(self, method: str):
        # Fixture trace only, outside the protected guard/run write set.
        with (self.case / "transport-calls").open("ab") as stream:
            require(stream.tell() < 4096, "fixture transport trace exceeded bound")
            stream.write(method.encode("ascii") + b"\n")
        raise AssertionError("read-only worker case reached transport: " + method)

    def identity(self, stage, context):
        return self._unexpected("identity")

    def render(self, view, context):
        return self._unexpected("render")

    def observe(self, context):
        return self._unexpected("observe")

    def spawn_create(self, context, control_fds):
        return self._unexpected("spawn_create")


def snapshot(case: Path, event: str) -> None:
    """Record bounded private fixture observations, outside production state."""
    import test_vps_timepad_state as guard

    require(event in {
        "predecessor-suppress", "predecessor-stop", "create-spawn",
        "normal-completed", "bound", "candidate-suppress", "candidate-start",
        "candidate-health", "candidate-restore",
    }, "unknown fixture observation")
    path = case / ("observed-" + event + ".json")
    if path.exists():
        require(event not in {"create-spawn", "candidate-start"},
                "fixture observed a repeated create/start")
        return
    no_socket()
    with guard.deploy_lock(str(case / "state"), 9):
        _, current = guard._read_guard_locked(str(case / "state"))
        lease = guard._read_execution_lease_locked(str(case / "state"))
        receipt_path = case / "state" / current["ownedRun"] / "timepad-create-completion.json"
        receipt = receipt_path.read_bytes() if receipt_path.exists() else None
        require(receipt is None or len(receipt) <= guard.MAX_CREATE_COMPLETION_BYTES,
                "fixture receipt observation exceeded bound")
        backend = json.loads((case / "forward-runtime.json").read_bytes())["backend"]
        environment = backend["Config"].pop("Env")
        environment_digest = hashlib.sha256(json.dumps(
            sorted(environment), separators=(",", ":"),
        ).encode()).hexdigest()
        value = {
            "current": current, "lease": lease,
            "receipt": receipt.decode("ascii") if receipt is not None else None,
            "backend": backend, "environmentDigest": environment_digest,
        }
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        require(len(raw) <= 65536, "fixture observation exceeded bound")
        private(path, raw)
        with (case / "observed-order").open("ab") as stream:
            require(stream.tell() < 4096, "fixture observation order exceeded bound")
            stream.write(event.encode("ascii") + b"\n")


class ObservedForwardTransport:
    """Delegate external facts unchanged; record actual lifecycle readbacks."""

    def __init__(self, case: Path, facts: dict):
        from forward import ForwardTransport

        self.case = case
        self.external = ForwardTransport(case, facts)

    def identity(self, stage, context):
        return self.external.identity(stage, context)

    def render(self, view, context):
        return self.external.render(view, context)

    def observe(self, context):
        import test_vps_timepad_state as guard

        result = self.external.observe(context)
        with guard.deploy_lock(context.state_root, 9):
            _, current = guard._read_guard_locked(context.state_root)
            request = current["runtimeRequest"]
            if request is not None and request["operation"] == "create" and \
                    request["lifecycle"] in {"normal-completed", "bound"}:
                snapshot(self.case, request["lifecycle"])
                if (self.case / "forward-scenario").read_text() == "binding-environment-drift":
                    observed = json.loads(result)
                    backend = next(item for item in observed["resources"]["containerInspections"]
                                   if item["Id"] == "a" * 64)
                    backend["Config"]["Env"].append("UNAPPROVED_FIXTURE_ENV=changed")
                    return json.dumps(observed, separators=(",", ":")).encode()
        return result

    def spawn_create(self, context, control_fds):
        snapshot(self.case, "create-spawn")
        return self.external.spawn_create(context, control_fds)


def external_docker(case: Path, arguments: list[str]) -> int:
    """Observe only the existing fixture's exact external Docker boundaries."""
    import forward

    isolated(case)
    require(Path(__file__).resolve() == case / "tools/create-controller.py",
            "fixture Docker adapter is not staged")
    predecessor, candidate = "f" * 64, "a" * 64
    events = {
        ("update", "--restart=no", predecessor): "predecessor-suppress",
        ("stop", "--time", "10", predecessor): "predecessor-stop",
        ("update", "--restart=no", candidate): "candidate-suppress",
        ("start", candidate): "candidate-start",
        ("update", "--restart=unless-stopped", candidate): "candidate-restore",
    }
    event = events.get(tuple(arguments))
    if event is not None:
        snapshot(case, event)
    elif arguments == [
        "inspect", candidate, "--format",
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
    ]:
        snapshot(case, "candidate-health")
    forward.docker(case, arguments, json.loads((case / "forward-facts.json").read_bytes()))
    return 0


def run(case: Path, scenario: str) -> int:
    installed_inputs = {
        name: (case / "root" / name).read_bytes()
        for name in (".env.production", "docker-compose.production.yml")
    }
    # This import resolves to the unchanged staged siblings. No source path,
    # transport selector or worker replacement is forwarded to production.
    import test_vps_timepad_supervisor as supervisor

    forward = scenario not in {"bootstrap", "bootstrap-mismatch", "deploy-blocked"}
    operation = "deploy" if forward or scenario == "deploy-blocked" else "bootstrap-guard"
    # The release wrapper maps bootstrap-guard onto the deploy supervisor
    # lifecycle; the guard operation remains in the controller arguments.
    supervisor_operation = "deploy" if operation == "bootstrap-guard" else operation
    arguments = [
        "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
        "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "0" * 64,
        "--revision", "0" * 40, "--version", "1.4.0", "--run-key", "31885558214-1",
        "--mode", "deploy", "--operation", operation,
    ]
    if operation == "bootstrap-guard":
        arguments += ["--initial-proof-id", "fixture-initial", "--bootstrap-id", "fixture-bootstrap"]
    else:
        arguments += (["--rollout-domain", "timepad-first-transition", "--initial-proof-id", "first-timepad"]
                      if forward else ["--rollout-domain", "initial-domain"])
    if forward:
        arguments[arguments.index("--image") + 1] = (
            "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64
        )
        arguments[arguments.index("--revision") + 1] = "3" * 40
        arguments[arguments.index("--version") + 1] = "1.2.3"
    os.environ["TEST_VPS_STATE_ROOT"] = str(case / "state")
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    if forward:
        fake = ObservedForwardTransport(case, json.loads((case / "forward-facts.json").read_bytes()))
        os.environ["PATH"] = str(case / "bin") + ":" + os.environ["PATH"]
        os.environ["TIMEPAD_FIXTURE_CASE"] = str(case)
    else:
        fake = RefusingTransport(case)
    parent, child = supervisor.socket_pair()
    pid = os.fork()
    if pid == 0:
        stage = "construct"
        try:
            parent.close()
            supervisor._close_except({child.fileno()})
            os.environ["TIMEPAD_FIXTURE_DIAGNOSTICS"] = "1"
            instance = supervisor.Supervisor(
                str(case / "state"), supervisor_operation, arguments, child,
                create_transport=fake,
            )
            stage = "run"
            os._exit(instance.run())
        except BaseException as error:
            error_name = type(error).__name__
            safe_name = error_name if (
                error_name.isascii() and error_name.isidentifier() and len(error_name) <= 64
            ) else "Exception"
            safe_reason = (
                str(error) if isinstance(error, supervisor.SupervisorError) and
                re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", str(error)) else "OTHER"
            )
            safe_stage = stage if stage in {"construct", "run"} else "unknown"
            safe_symbols = {
                "Attempt", "Children", "__init__", "boot_id", "linux_preflight",
                "process_identity", "reject",
            }
            symbols = [
                frame.name if frame.name in safe_symbols else "other"
                for frame in traceback.extract_tb(error.__traceback__)[-4:]
            ]
            private(
                case / "supervisor-error",
                (
                    safe_stage + ":" + safe_name + ":" + safe_reason + ":" +
                    ",".join(symbols) + "\n"
                ).encode("ascii"),
            )
            os._exit(1)
    child.close()
    end = time.monotonic_ns() + (600 if forward else 90) * supervisor.NS
    frames = []
    status = None
    passive_keeper = False
    try:
        while time.monotonic_ns() < end:
            no_socket()
            with selectors.DefaultSelector() as selector:
                selector.register(parent, selectors.EVENT_READ)
                if not selector.select(0.05):
                    continue
            try:
                frame, _ = supervisor.receive_frame(parent)
            except supervisor.SupervisorError as error:
                detail = (
                    (case / "supervisor-error").read_text().strip()
                    if (case / "supervisor-error").exists() else "NO_CHILD_EXCEPTION"
                )
                raise AssertionError(
                    "fixture supervisor channel closed: protocol=" + str(error) +
                    " child=" + detail,
                ) from None
            require(len(frames) < 256, "fixture relay inventory exceeded bound")
            frames.append(frame)
            if len(frames) == 1:
                require(frame.get("kind") == "hello" and
                        frame.get("supervisor") == supervisor.lease_identity(supervisor.process_identity(pid)),
                        "fixture supervisor identity was not kernel-bound")
                supervisor.send_frame(parent, {"kind": "ready", "attempt": frame["attempt"]})
            else:
                require(frame.get("attempt") == frames[0]["attempt"], "fixture relay attempt changed")
                require(frame.get("kind") in {"clock", "result"}, "fixture relay message is not fixed")
            if frame["kind"] == "result":
                if forward and scenario != "forward" and frame["reason"] == "QUIESCENCE_UNCONFIRMED":
                    # The refusal is not a normal exit. Observe the retained
                    # lock before fixture-only teardown, never fake a drain.
                    import fcntl

                    require(frame["status"] != 0, "uncertain attempt reported success")
                    require(os.waitpid(pid, os.WNOHANG) == (0, 0), "passive keeper already exited")
                    children_path = Path(f"/proc/{pid}/task/{pid}/children")
                    drain_end = min(end, time.monotonic_ns() + 10 * supervisor.NS)
                    while children_path.read_text().strip() and time.monotonic_ns() < drain_end:
                        no_socket()
                        time.sleep(0.05)
                    require(not children_path.read_text().strip(),
                            "uncertain keeper still has writers")
                    with (case / "state/.deploy.lock").open("rb") as lock:
                        try:
                            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            pass
                        else:
                            raise AssertionError("uncertain keeper released FD9")
                    private(case / "passive-keeper-observed", b"childless;lock-held;not-normal-exit\n")
                    passive_keeper = True
                    status = frame["status"]
                    break
                while time.monotonic_ns() < end:
                    no_socket()
                    reaped, actual = os.waitpid(pid, os.WNOHANG)
                    if reaped:
                        status = os.waitstatus_to_exitcode(actual)
                        break
                    time.sleep(0.01)
                require(status is not None and status == frame["status"],
                        "fixture result did not match actual supervisor exit")
                break
        require(status is not None, "actual controller worker exceeded fixture deadline")
        no_socket()
        if forward:
            import test_vps_timepad_state as guard

            current = (
                json.loads((case / "observed-normal-completed.json").read_bytes())["current"]
                if passive_keeper else guard.read_guard(str(case / "state"))[1]
            )
            effects = (case / "forward-effects").read_text().splitlines() if (
                case / "forward-effects"
            ).exists() else []
            starts = [effect for effect in effects if effect.startswith("start:")]
            run_path = case / "state/31885558214-1-final-deploy"
            if scenario == "forward":
                if status != 0 or current["phase"] != "COMMITTED":
                    effect_kinds = ",".join(
                        effect.split(":", 1)[0] for effect in effects
                    ) or "none"
                    phase = current.get("phase")
                    if phase not in {
                        "READY", "PREPARED", "CUTOVER_POSSIBLE", "VERIFYING",
                        "COMMITTING", "COMMITTED", "RECOVERY_REQUIRED",
                        "FORWARD_RECOVERING", "ROLLING_BACK", "ROLLED_BACK",
                    }:
                        phase = "unknown"
                    failure = current.get("firstFailure")
                    if not isinstance(failure, str) or not re.fullmatch(
                        r"[A-Z][A-Z0-9_]{0,63}", failure,
                    ):
                        failure = "none"
                    raise AssertionError(
                        "actual normal forward did not commit: phase=" + phase +
                        " failure=" + failure + " effects=" + effect_kinds,
                    )
                require(status == 0 and current["phase"] == "COMMITTED",
                        "actual normal forward did not commit")
                require(starts == ["start:" + "a" * 64], "candidate start inventory is not exact")
                require((run_path / "timepad-create-completion.json").is_file(),
                        "actual completion publisher receipt missing")
                require(current["ownedChild"] is None and current["containerId"] == "a" * 64,
                        "actual candidate binding or child drain missing")
            else:
                require(status != 0 and not starts, "refused forward started a candidate")
            private(case / "forward-relay-result.json", json.dumps(frames[-1], sort_keys=True).encode())
            print("ACTUAL_FORWARD_CONTROLLER_PASS: scenario=" + scenario + " no_socket=true", flush=True)
            return 0
        require(not (case / "transport-calls").exists(), "read-only worker attempted guarded create")
        require(all((case / "root" / name).read_bytes() == value
                    for name, value in installed_inputs.items()),
                "gated worker changed installed configuration")
        require(not (case / "state/.provider-transaction.current").exists(),
                "gated worker published provider transaction")
        require(not (case / "state/31885558214-1-final-deploy").exists(),
                "gated worker published an owned deploy run")
        # The subprocess exit and terminal lease are real observations, not
        # caller-supplied state or a manufactured publication acknowledgment.
        private(case / "relay-result.json", json.dumps(frames[-1], sort_keys=True).encode())
        print("ACTUAL_CONTROLLER_CHANNEL_PASS: scenario=" + scenario +
              " no_socket=true create_pipeline=NOT_PROVEN", flush=True)
        return 0
    finally:
        parent.close()
        if passive_keeper:
            # Only this forked fixture process is killed, after childlessness,
            # lock retention and a non-success result were observed. Durable
            # unresolved state remains unchanged; this is not protocol success.
            os.kill(pid, signal.SIGKILL)
            waited, actual = os.waitpid(pid, 0)
            require(waited == pid and os.waitstatus_to_exitcode(actual) == -signal.SIGKILL,
                    "fixture passive-keeper teardown failed")
        elif status is None:
            # Closing the real relay revokes authority. Never manufacture an
            # ACK, unlock FD9 or kill only the supervisor and orphan its workers.
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            # Do not orphan a passive keeper by letting the fixture exit first.
            # The enclosing timeout owns the process-group hard-kill bound.
            os.waitpid(pid, 0)


def recover(case: Path, arguments: list[str]) -> int:
    """Relay a historical case to the actual worker, not production RealTransport.

    A quiescence refusal deliberately leaves the real passive keeper in the
    fixture PID namespace, just as the public relay does. Only a positive
    terminal result is accompanied by an actual wait/exit assertion.
    """
    import test_vps_timepad_supervisor as supervisor
    from forward import ForwardTransport

    require(Path(__file__).resolve() == case / "tools/create-controller.py",
            "historical controller is not staged")
    require(arguments.count("--operation") == 1 and
            arguments[arguments.index("--operation") + 1] == "forward-recover",
            "historical controller operation is not fixed")
    require(arguments.count("--root") == 1 and
            arguments[arguments.index("--root") + 1] == str(case / "root"),
            "historical controller root is not fixed")
    require(os.environ.get("TEST_VPS_STATE_ROOT") == str(case / "state"),
            "historical state root is not fixed")
    no_socket()
    fake = ForwardTransport(
        case, {}, recovery_runtime=case / "runtime.json", diagnostics=True,
    )
    parent, child = supervisor.socket_pair()
    pid = os.fork()
    if pid == 0:
        try:
            parent.close()
            os.setsid()
            supervisor._close_except({child.fileno()})
            # Refused attempts can retain FD9 after the relay has returned.
            # Match the production relay: a passive keeper must not retain
            # any caller output pipe.
            null = os.open("/dev/null", os.O_RDWR)
            for fd in (0, 1):
                os.dup2(null, fd)
            diagnostic_path = os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTIC_FILE")
            if diagnostic_path is not None:
                require(Path(diagnostic_path) == case / "recovery-diagnostics",
                        "fixture diagnostic destination is not fixed")
                diagnostic_fd = os.open(
                    diagnostic_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600,
                )
                os.dup2(diagnostic_fd, 2)
                if diagnostic_fd > 2:
                    os.close(diagnostic_fd)
            else:
                os.dup2(null, 2)
            if null > 2:
                os.close(null)
            instance = supervisor.Supervisor(
                str(case / "state"), "forward-recover", arguments, child,
                create_transport=fake,
            )
            os._exit(instance.run())
        except BaseException:
            os._exit(1)
    child.close()
    reaped = False
    hello = None
    try:
        supervisor._wait_readable(parent, time.monotonic_ns() + 5 * supervisor.NS)
        hello, _ = supervisor.receive_frame(parent)
        require(set(hello) == {"kind", "attempt", "supervisor", "hardEndNs", "watchEndNs"}
                and hello["kind"] == "hello" and
                hello["supervisor"] == supervisor.lease_identity(supervisor.process_identity(pid)),
                "historical supervisor identity is not kernel-bound")
        private(
            case / ("recovery-supervisor-" + hello["attempt"] + ".json"),
            json.dumps({
                "attempt": hello["attempt"], "supervisor": hello["supervisor"],
                "hardEndNs": hello["hardEndNs"], "watchEndNs": hello["watchEndNs"],
            }, sort_keys=True).encode(),
        )
        supervisor.send_frame(parent, {"kind": "ready", "attempt": hello["attempt"]})
        hard_end, watch_end = hello["hardEndNs"], hello["watchEndNs"]
        for _ in range(256):
            no_socket()
            supervisor._wait_readable(parent, hard_end if hard_end is not None else watch_end)
            frame, _ = supervisor.receive_frame(parent)
            require(frame.get("attempt") == hello["attempt"], "historical relay attempt changed")
            if frame.get("kind") == "clock":
                require(set(frame) == {"kind", "attempt", "hardEndNs", "watchEndNs"} and
                        (hard_end is None or frame["hardEndNs"] == hard_end),
                        "historical relay clock changed")
                hard_end, watch_end = frame["hardEndNs"], frame["watchEndNs"]
                continue
            require(set(frame) == {"kind", "attempt", "status", "reason", "outcome"} and
                    frame["kind"] == "result" and frame["status"] == 1 and
                    frame["reason"] in {"RECOVERY_REQUIRED", "QUIESCENCE_UNCONFIRMED"},
                    "historical refusal result is not fixed")
            if frame["reason"] == "QUIESCENCE_UNCONFIRMED":
                private(case / ("recovery-channel-" + hello["attempt"] + ".json"), json.dumps({
                    "attempt": hello["attempt"], "failure": "RESULT_QUIESCENCE_UNCONFIRMED",
                    "state": "result",
                }, sort_keys=True).encode())
            if frame["reason"] == "RECOVERY_REQUIRED":
                end = time.monotonic_ns() + 5 * supervisor.NS
                if hard_end is not None:
                    end = min(end, hard_end)
                while time.monotonic_ns() < end:
                    no_socket()
                    waited, status = os.waitpid(pid, os.WNOHANG)
                    if waited:
                        reaped = True
                        require(os.waitstatus_to_exitcode(status) == frame["status"],
                                "historical result did not match actual supervisor exit")
                        break
                    time.sleep(0.01)
                require(reaped, "historical terminal supervisor did not exit")
            private(case / ("recovery-relay-" + hello["attempt"] + ".json"), json.dumps({
                "hello": hello, "result": frame, "reaped": reaped,
                "transportEvents": (
                    (case / "recovery-transport-events").read_text().splitlines()
                    if (case / "recovery-transport-events").exists() else []
                ),
            }, sort_keys=True).encode())
            outcome = frame["outcome"]
            require(outcome is None or (
                frame["reason"] == "RECOVERY_REQUIRED" and
                supervisor.REFUSAL_OUTCOMES.get(outcome) == "forward-recover"
            ), "historical refusal outcome is not fixed")
            if outcome is not None:
                print("test VPS deployment failed: " + outcome, file=sys.stderr, flush=True)
            print("schema_guard=" + frame["reason"], flush=True)
            no_socket()
            return frame["status"]
        raise AssertionError("historical relay inventory exceeded bound")
    except (OSError, supervisor.SupervisorError) as error:
        # Match the public relay when lock/lease admission closes the channel
        # before a result. No terminal receipt or drained lease is fabricated.
        if hello is not None:
            failure = (
                str(error) if isinstance(error, supervisor.SupervisorError) and
                re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", str(error)) else "OS_ERROR"
            )
            private(case / ("recovery-channel-" + hello["attempt"] + ".json"), json.dumps({
                "attempt": hello["attempt"], "failure": failure, "state": "closed-or-error",
            }, sort_keys=True).encode())
        print("schema_guard=QUIESCENCE_UNCONFIRMED", flush=True)
        return 1
    finally:
        parent.close()
        if not reaped:
            os.waitpid(pid, os.WNOHANG)


def main() -> int:
    if sys.argv[1:2] == ["--external-docker"]:
        return external_docker(Path(os.environ["TIMEPAD_FIXTURE_CASE"]), sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True)
    parser.add_argument("--scenario", choices=(
        "bootstrap", "bootstrap-mismatch", "deploy-blocked", "forward",
        "suppress-refused", "stop-refused", "binding-environment-drift",
    ), required=True)
    parser.add_argument("--staged", action="store_true")
    options = parser.parse_args()
    isolated(options.case)
    if not options.staged:
        prepare(options.case, options.scenario)
        os.execv(sys.executable, [
            sys.executable, "-B", str(options.case / "tools/create-controller.py"),
            "--case", str(options.case), "--scenario", options.scenario, "--staged",
        ])
    require(Path(__file__).resolve() == options.case / "tools/create-controller.py",
            "fixture stage identity is not fixed")
    if options.scenario not in {"bootstrap", "bootstrap-mismatch", "deploy-blocked"}:
        require(run(options.case, "bootstrap") == 0, "actual bootstrap did not complete")
    return run(options.case, options.scenario)


if __name__ == "__main__":
    raise SystemExit(main())
