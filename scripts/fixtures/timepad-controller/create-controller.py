#!/usr/bin/env python3
"""Actual-worker channel fixture, not successful guarded-create acceptance.

Only the explicit Supervisor constructor receives the fixture transport. The
production worker, state/provider helpers, locks, grants and terminal publisher
are unchanged. Bootstrap is executable here; guarded deploy still refuses at
its existing lifecycle gate before any create or start. The forward scenarios
are integration scaffolding until that production lifecycle is completed and
its gate is lifted; their presence is not evidence of successful guarded create.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import sys
import time


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

        facts = external.fixture_data(source)
        shutil.copyfile(Path(__file__).with_name("forward.py"), case / "tools/forward.py")
        (case / "bin").mkdir(mode=0o700)
        for kind in ("docker", "curl"):
            shutil.copyfile(Path(__file__).with_name("forward-" + kind), case / "bin" / kind)
            (case / "bin" / kind).chmod(0o700)
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
    arguments = [
        "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
        "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "0" * 64,
        "--revision", "0" * 40, "--version", "1.4.0", "--run-key", "fixture-channel-1",
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
        from forward import ForwardTransport

        fake = ForwardTransport(case, json.loads((case / "forward-facts.json").read_bytes()))
        os.environ["PATH"] = str(case / "bin") + ":" + os.environ["PATH"]
        os.environ["TIMEPAD_FIXTURE_CASE"] = str(case)
    else:
        fake = RefusingTransport(case)
    parent, child = supervisor.socket_pair()
    pid = os.fork()
    if pid == 0:
        try:
            parent.close()
            supervisor._close_except({child.fileno()})
            instance = supervisor.Supervisor(
                str(case / "state"), operation, arguments, child, create_transport=fake,
            )
            os._exit(instance.run())
        except BaseException:
            os._exit(1)
    child.close()
    end = time.monotonic_ns() + (600 if forward else 90) * supervisor.NS
    frames = []
    status = None
    try:
        while time.monotonic_ns() < end:
            no_socket()
            with selectors.DefaultSelector() as selector:
                selector.register(parent, selectors.EVENT_READ)
                if not selector.select(0.05):
                    continue
            frame, _ = supervisor.receive_frame(parent)
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

            _, current = guard.read_guard(str(case / "state"))
            effects = (case / "forward-effects").read_text().splitlines() if (
                case / "forward-effects"
            ).exists() else []
            starts = [effect for effect in effects if effect.startswith("start:")]
            run_path = case / "state/fixture-channel-1-final-deploy"
            if scenario == "forward":
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
        require(not (case / "state/fixture-channel-1-final-deploy").exists(),
                "gated worker published an owned deploy run")
        # The subprocess exit and terminal lease are real observations, not
        # caller-supplied state or a manufactured publication acknowledgment.
        private(case / "relay-result.json", json.dumps(frames[-1], sort_keys=True).encode())
        print("ACTUAL_CONTROLLER_CHANNEL_PASS: scenario=" + scenario +
              " no_socket=true create_pipeline=NOT_PROVEN", flush=True)
        return 0
    finally:
        parent.close()
        if status is None:
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
            for fd in (0, 1, 2):
                os.dup2(null, fd)
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
    try:
        supervisor._wait_readable(parent, time.monotonic_ns() + 5 * supervisor.NS)
        hello, _ = supervisor.receive_frame(parent)
        require(set(hello) == {"kind", "attempt", "supervisor", "hardEndNs", "watchEndNs"}
                and hello["kind"] == "hello" and
                hello["supervisor"] == supervisor.lease_identity(supervisor.process_identity(pid)),
                "historical supervisor identity is not kernel-bound")
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
    except (OSError, supervisor.SupervisorError):
        # Match the public relay when lock/lease admission closes the channel
        # before a result. No terminal receipt or drained lease is fabricated.
        print("schema_guard=QUIESCENCE_UNCONFIRMED", flush=True)
        return 1
    finally:
        parent.close()
        if not reaped:
            os.waitpid(pid, os.WNOHANG)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True)
    parser.add_argument("--scenario", choices=(
        "bootstrap", "bootstrap-mismatch", "deploy-blocked", "forward",
        "suppress-refused", "stop-refused",
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
