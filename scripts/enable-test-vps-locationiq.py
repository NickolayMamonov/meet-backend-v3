#!/usr/bin/env python3
"""One exact-image OFF->ON activation. No credential transfer or HTTP probes."""

import sys

sys.dont_write_bytecode = True

import copy
from dataclasses import dataclass
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import selectors
import signal
import stat
import subprocess
import tempfile
import time

from test_vps_file_trust import Rejected, directory, identity, no_acl, private_file

SPEC = importlib.util.spec_from_file_location(
    "locationiq_off", Path(__file__).with_name("configure-test-vps-locationiq.py"))
off = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(off)

ROOT = Path("/opt/meet-backend")
STATE = Path("/var/lib/meet-test-vps-deploy")
RUNTIME = Path("/var/lib/meet-production")
IMAGE = "ghcr.io/nickolaymamonov/meet-backend-v3"
SOURCE = "https://github.com/NickolayMamonov/meet-backend-v3"
LIMIT = 1_048_576
SIGNALS = {signal.SIGALRM, signal.SIGTERM, signal.SIGINT, signal.SIGHUP}
CHILD_ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
             "LC_ALL": "C", "HOME": "/root", "PYTHONDONTWRITEBYTECODE": "1",
             # Override persisted currentContext for inspections and the wrapper.
             "DOCKER_HOST": "unix:///var/run/docker.sock"}


@dataclass(frozen=True)
class Approved:
    source: str
    digest: str
    image_id: str
    version: str
    run_key: str

    def __post_init__(self):
        patterns = (r"[0-9a-f]{40}", r"sha256:[0-9a-f]{64}", r"sha256:[0-9a-f]{64}",
                    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",
                    r"[1-9][0-9]*-[1-9][0-9]*")
        values = (self.source, self.digest, self.image_id, self.version, self.run_key)
        if any(len(value) > 128 or not re.fullmatch(pattern, value)
               for pattern, value in zip(patterns, values)):
            raise Rejected("invalid_approved_tuple")

    @property
    def image(self):
        return IMAGE + "@" + self.digest


class Commands:
    """One absolute budget and a tracked process group, including inspections."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.end = clock() + 300
        self.phase_end = self.end - 30
        self.stopping = False
        self.child = None

    def remaining(self, cap):
        remaining = min(cap, self.phase_end - self.clock())
        if remaining <= 0:
            raise Rejected("phase_deadline")
        return remaining

    def begin_stop(self):
        if not self.stopping:
            self.stopping = True
            self.phase_end = min(self.end, self.clock() + 30)

    def reap(self):
        if self.child is None:
            return
        child = self.child
        # The CLI leader may already have exited while descendants hold pipes.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=self.remaining(5))
        while True:
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                break
            if self.remaining(0.05) <= 0:
                raise Rejected("child_group_unresolved")
            time.sleep(min(0.01, self.remaining(0.01)))
        child.stdout.close()
        if child.stdin is not None and not child.stdin.closed:
            child.stdin.close()
        self.child = None

    def run(self, arguments, cap=10, stdin=None, extra_env=None):
        end = self.clock() + self.remaining(cap)
        environment = dict(CHILD_ENV)
        if extra_env:
            environment.update(extra_env)
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
        try:
            child = subprocess.Popen(arguments, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     env=environment, start_new_session=True)
            self.child = child
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        output = bytearray()
        try:
            if stdin is not None:
                # Fixed render-only override contains just a bounded candidate path.
                if len(stdin) > 4096:
                    raise Rejected("render_input_budget")
                child.stdin.write(stdin)
                child.stdin.close()
            with selectors.DefaultSelector() as selector:
                selector.register(child.stdout, selectors.EVENT_READ)
                while True:
                    remaining = min(end, self.phase_end) - self.clock()
                    if remaining <= 0 or not selector.select(remaining):
                        raise Rejected("command_deadline")
                    chunk = os.read(child.stdout.fileno(), min(65536, LIMIT + 1 - len(output)))
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > LIMIT:
                        raise Rejected("command_budget")
                if child.wait(timeout=min(self.remaining(cap), max(0.001, end - self.clock()))) != 0:
                    raise Rejected("command_failed")
            # Refuse lingering descendants even after a successful leader.
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                child.stdout.close()
                self.child = None
            else:
                raise Rejected("child_group_unresolved")
            return bytes(output)
        except BaseException:
            # Caller enters the single stop phase before terminating this group.
            raise


def decode(raw):
    return json.loads(raw, object_pairs_hook=off.unique_object)


def environment(items):
    result = {}
    for item in items:
        name, value = item.split("=", 1)
        if name in result or off.ambiguous(name, value):
            raise Rejected("ambiguous_environment")
        result[name] = value
    return result


def env_file(raw):
    if not raw.endswith(b"\n") or b"$" in raw or b"\0" in raw:
        raise Rejected("invalid_environment")
    entries = []
    for line in raw.decode("utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", line):
            raise Rejected("noncanonical_environment")
        entries.append(line)
    return environment(entries)


def release_fields(raw):
    result = {}
    for line in raw.decode("utf-8").splitlines():
        match = re.fullmatch(r"(BACKEND_IMAGE|BACKEND_REVISION|BACKEND_VERSION)=(.*)", line)
        if match:
            name, value = match.groups()
            if name in result:
                raise Rejected("duplicate_release_field")
            result[name] = value
    return result


def one_record(raw):
    records = decode(raw)
    if not isinstance(records, list) or len(records) != 1:
        raise Rejected("unexpected_inspection")
    return records[0]


class Activation:
    def __init__(self, approved, *, root=ROOT, state=STATE, runtime=RUNTIME,
                 stage=None, commands=None):
        self.approved = approved
        self.root, self.state, self.runtime = root, state, runtime
        self.stage = stage or Path(__file__).resolve().parent
        self.commands = commands or Commands()
        self.witnesses = {}
        self.temporary = None
        self.published = False
        self.failed = False
        self.committed = False
        self.cleanup_failed = False
        self.parent = -1
        self.stop = "not_attempted"

    def read(self, path, *, tool=False):
        parent = directory(path.parent)
        try:
            if tool:
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                try:
                    info = os.fstat(fd)
                    if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_gid != 0
                            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o022):
                        raise Rejected("unsafe_tool")
                    no_acl(fd)
                    data = os.read(fd, LIMIT + 1)
                    if len(data) > LIMIT or identity(info) != identity(os.fstat(fd)):
                        raise Rejected("tool_changed")
                finally:
                    os.close(fd)
            else:
                fd, data, info = private_file(parent, path.name)
                os.close(fd)
            return data, identity(info)
        finally:
            os.close(parent)

    def remember(self, path, *, tool=False):
        value = self.read(path, tool=tool)
        self.witnesses[path] = (value, tool)
        return value[0]

    def unchanged(self):
        self.commands.remaining(10)
        for path, (value, tool) in self.witnesses.items():
            if self.read(path, tool=tool) != value:
                raise Rejected("admission_changed")

    def compose(self, env_path, arguments, candidate=False):
        base = ["docker", "compose", "-p", "meet-production", "--project-directory", str(self.root),
                "--env-file", str(env_path), "-f", str(self.runtime / "active-compose.yml"),
                "-f", str(self.runtime / "active-runtime.override.yml")]
        stdin = None
        if candidate:
            # --env-file affects interpolation, not service env_file. Append a
            # render-only candidate env file; never pass this override to up/stop.
            base += ["-f", "-"]
            stdin = json.dumps({"services": {"backend": {"env_file": [str(env_path)]}}}).encode()
        return self.commands.run(base + arguments, stdin=stdin)

    def render(self, env_path, candidate=False):
        model = decode(self.compose(env_path, ["config", "--format", "json"], candidate))
        raw_hash = self.compose(env_path, ["config", "--hash", "backend"], candidate).decode().strip()
        match = re.fullmatch(r"backend ([0-9a-f]{64})", raw_hash)
        if (not match or model.get("name") != "meet-production"
                or model["services"]["backend"]["image"] != self.approved.image):
            raise Rejected("invalid_render")
        return model, match[1]

    def wrapper(self, arguments, cap):
        return self.commands.run(["bash", str(self.stage / "production-compose.sh"), *arguments],
                                 cap=cap, extra_env={"PRODUCTION_ROOT": str(self.root),
                                                   "PRODUCTION_STATE_DIR": str(self.runtime)})

    def backend(self, flag, model, config_hash, image):
        ids = self.commands.run(["docker", "ps", "--no-trunc", "-q", "--filter",
                                 "label=com.docker.compose.service=backend"]).splitlines()
        if len(ids) != 1 or not re.fullmatch(rb"[0-9a-f]{64}", ids[0]):
            raise Rejected("single_backend_required")
        record = one_record(self.commands.run(["docker", "inspect", ids[0].decode()]))
        config, host = record["Config"], record["HostConfig"]
        labels = config["Labels"]
        expected_env = environment(image["Config"]["Env"])
        expected_env.update(model["services"]["backend"]["environment"])
        actual_env = environment(config["Env"])
        if (record["Id"] != ids[0].decode() or record["Image"] != self.approved.image_id
                or config["Image"] != self.approved.image or config["User"] != "10001:10001"
                or config["Entrypoint"] != ["java", "-jar", "app.jar"]
                or config.get("Cmd") not in (None, [])
                or labels.get("com.docker.compose.project") != "meet-production"
                or labels.get("com.docker.compose.service") != "backend"
                or labels.get("com.docker.compose.config-hash") != config_hash
                or record["State"]["Running"] is not True
                or record["State"]["Health"]["Status"] != "healthy"
                or actual_env != expected_env or actual_env.get("GEOCODER_ENABLED") != flag
                or actual_env.get("LOCATIONIQ_KEY") != self.key
                or host["ReadonlyRootfs"] is not True
                or host["RestartPolicy"]["Name"] != "unless-stopped"
                or host["LogConfig"]["Type"] != "local" or host["Memory"] <= 0
                or "ALL" not in host["CapDrop"]
                or "no-new-privileges:true" not in host["SecurityOpt"] or "/tmp" not in host["Tmpfs"]
                or labels.get("org.opencontainers.image.revision") != self.approved.source
                or labels.get("org.opencontainers.image.version") != self.approved.version
                or labels.get("org.opencontainers.image.source") != SOURCE):
            raise Rejected("runtime_contract")
        ports = record["NetworkSettings"]["Ports"]
        bindings = ports.get("8080/tcp", [])
        if (len(bindings) != 1 or bindings[0]["HostIp"] != "127.0.0.1"
                or not re.fullmatch(r"[1-9][0-9]{0,4}", bindings[0]["HostPort"])
                or int(bindings[0]["HostPort"]) > 65535
                or any(value for name, value in ports.items() if name != "8080/tcp")):
            raise Rejected("runtime_ports")
        uploads = [mount for mount in record["Mounts"] if mount["Destination"] == "/data/uploads"]
        if (len(uploads) != 1 or uploads[0].get("Type") != "volume"
                or uploads[0].get("Name") != "meet-production_uploads_data"):
            raise Rejected("runtime_mounts")
        return record

    def fingerprint(self, record):
        # Only container identity/start/config hash and the enable flag may change.
        config = copy.deepcopy(record["Config"])
        config["Env"] = sorted(item for item in config["Env"]
                               if not item.startswith("GEOCODER_ENABLED="))
        config["Labels"].pop("com.docker.compose.config-hash", None)
        # Compose may record which container this recreation replaced.
        config["Labels"].pop("com.docker.compose.replace", None)
        config.pop("Hostname", None)
        return (config, record["HostConfig"], record["Mounts"],
                record["NetworkSettings"]["Ports"])

    def postgres(self):
        ids = self.commands.run(["docker", "ps", "--no-trunc", "-q", "--filter",
                                 "label=com.docker.compose.project=meet-production",
                                 "--filter", "label=com.docker.compose.service=postgres"]).splitlines()
        if len(ids) != 1 or not re.fullmatch(rb"[0-9a-f]{64}", ids[0]):
            raise Rejected("single_postgres_required")
        record = one_record(self.commands.run(["docker", "inspect", ids[0].decode()]))
        mounts = [item for item in record["Mounts"]
                  if item["Destination"] == "/var/lib/postgresql/data"]
        if (record["Id"] != ids[0].decode() or record["State"]["Running"] is not True
                or record["State"]["Health"]["Status"] != "healthy"
                or record["Config"]["Labels"].get("com.docker.compose.project") != "meet-production"
                or record["Config"]["Labels"].get("com.docker.compose.service") != "postgres"
                or any(record["NetworkSettings"]["Ports"].values())
                or len(mounts) != 1 or mounts[0].get("Name") != "meet-production_postgres_data"):
            raise Rejected("postgres_contract")
        return (record["Id"], record["Image"], record["Config"], record["HostConfig"],
                record["Mounts"], record["NetworkSettings"]["Ports"])

    def cleanup(self):
        if self.temporary is not None:
            self.temporary.unlink()
            self.temporary = None

    def fail(self):
        if self.failed:
            return
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
        try:
            self.failed = True
            for number in SIGNALS:
                signal.signal(number, signal.SIG_IGN)
            self.commands.begin_stop()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        try:
            self.commands.reap()
            if self.published:
                self.unchanged()
                self.wrapper(["stop", "-t", "10", "backend"], cap=20)
                self.stop = "command_completed"
                ids = self.commands.run(["docker", "ps", "--no-trunc", "-q", "--filter",
                                         "label=com.docker.compose.service=backend"]).strip()
                if not ids:
                    self.stop = "verified_stopped"
                else:
                    self.stop = "unknown"
        except BaseException:
            self.stop = "unknown" if self.published else "not_attempted"
        finally:
            try:
                self.commands.reap()
            except BaseException:
                if self.published:
                    self.stop = "unknown"
            try:
                self.cleanup()
            except BaseException:
                self.cleanup_failed = True

    def execute(self):
        state_fd = lock_fd = -1
        self.parent = directory(self.root)
        try:
            state_fd = directory(self.state)
            lock_fd, _, _ = private_file(state_fd, ".deploy.lock", deployment_lock=True)
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                self.activate()
                self.cleanup()
                self.commands.remaining(1)
                self.committed = True
                return {"outcome": "committed", "published": True, "stop": "not_attempted"}
            except BaseException:
                self.fail()
                return {"outcome": "manual_intervention_required" if self.published or self.cleanup_failed else "rejected",
                        "published": self.published, "stop": self.stop}
        finally:
            for fd in (lock_fd, state_fd, self.parent):
                if fd >= 0:
                    os.close(fd)

    def activate(self):
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            if os.path.lexists(self.state / name):
                raise Rejected("unresolved_transaction")
        for name in ("production-compose.sh", "enable-test-vps-locationiq.py",
                     "configure-test-vps-locationiq.py", "test_vps_file_trust.py"):
            self.remember(self.stage / name, tool=True)
        deployment = self.state / (self.approved.run_key + "-final-deploy")
        terminal = decode(self.remember(deployment / "terminal.json"))
        if (terminal.get("schemaVersion") != 1 or terminal.get("outcome") != "committed"
                or terminal.get("runKey") != self.approved.run_key):
            raise Rejected("deployment_not_committed")
        saved = release_fields(self.remember(deployment / "config.env.target"))
        before = self.remember(self.root / ".env.production")
        current = env_file(before)
        for values in (saved, current):
            if (values.get("BACKEND_IMAGE") != self.approved.image
                    or values.get("BACKEND_REVISION") != self.approved.source
                    or values.get("BACKEND_VERSION") != self.approved.version):
                raise Rejected("deployment_tuple_mismatch")
        if current.get("GEOCODER_ENABLED") != "false" or not current.get("LOCATIONIQ_KEY"):
            raise Rejected("explicit_off_key_required")
        self.key = off.validate_key(current["LOCATIONIQ_KEY"].encode())
        if off.candidate(before, self.key) != before:
            raise Rejected("noncanonical_off")
        for active, snapshot in (("active-compose.yml", "config.base-compose.yml"),
                                 ("active-runtime.override.yml", "target-runtime.override.yml")):
            if self.remember(self.runtime / active) != self.remember(deployment / snapshot):
                raise Rejected("active_compose_mismatch")
        image = one_record(self.commands.run(["docker", "image", "inspect", self.approved.image]))
        if (image["Id"] != self.approved.image_id or image["Config"]["User"] != "10001:10001"
                or image["Config"]["Labels"].get("org.opencontainers.image.revision") != self.approved.source
                or image["Config"]["Labels"].get("org.opencontainers.image.version") != self.approved.version
                or image["Config"]["Labels"].get("org.opencontainers.image.source") != SOURCE):
            raise Rejected("image_tuple_mismatch")
        model, old_hash = self.render(self.root / ".env.production")
        old = self.backend("false", model, old_hash, image)
        postgres = self.postgres()
        # Full-line replacement only; reject accidental matches in other values.
        lines = before.splitlines(keepends=True)
        after = b"".join(line.replace(b"GEOCODER_ENABLED=false", b"GEOCODER_ENABLED=true", 1)
                         if line.rstrip(b"\r\n") == b"GEOCODER_ENABLED=false" else line for line in lines)
        fd, name = tempfile.mkstemp(prefix=".locationiq-enable-", dir=self.root)
        self.temporary = Path(name)
        try:
            os.fchmod(fd, 0o600)
            os.fchown(fd, 0, 0)
            with os.fdopen(os.dup(fd), "wb") as stream:
                stream.write(after)
                stream.flush()
            os.fsync(fd)
        finally:
            os.close(fd)
        expected, expected_hash = self.render(self.temporary, candidate=True)
        candidate_witness = self.read(self.temporary)
        if candidate_witness[0] != after:
            raise Rejected("candidate_changed")
        allowed = copy.deepcopy(model)
        allowed["services"]["backend"]["environment"]["GEOCODER_ENABLED"] = "true"
        if expected != allowed:
            raise Rejected("render_changes_unrelated_state")
        self.unchanged()
        if self.backend("false", model, old_hash, image) != old:
            raise Rejected("runtime_changed")
        if self.read(self.temporary) != candidate_witness:
            raise Rejected("candidate_changed")
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
        try:
            os.replace(self.temporary, self.root / ".env.production")
            self.published = True
            self.temporary = None
            self.witnesses.pop(self.root / ".env.production")
            self.remember(self.root / ".env.production")
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        os.fsync(self.parent)
        actual, actual_hash = self.render(self.root / ".env.production")
        if actual != expected or actual_hash != expected_hash:
            raise Rejected("published_render_mismatch")
        self.unchanged()
        self.wrapper(["up", "-d", "--no-deps", "--no-build", "--pull", "never",
                      "--force-recreate", "--wait", "--wait-timeout", "180", "backend"], cap=210)
        replacement = self.backend("true", expected, expected_hash, image)
        if (replacement["Id"] == old["Id"]
                or replacement["Config"]["Labels"].get("com.docker.compose.replace") not in (None, old["Id"])
                or self.fingerprint(replacement) != self.fingerprint(old)):
            raise Rejected("replacement_contract")
        if self.postgres() != postgres:
            raise Rejected("postgres_changed")
        self.unchanged()


def main():
    activation = None
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        if os.geteuid() != 0 or len(sys.argv) != 6:
            raise Rejected("root_exact_tuple_required")
        approved = Approved(*sys.argv[1:])
        activation = Activation(approved)
        def interrupted(_number, _frame):
            raise Rejected("activation_interrupted")
        for number in SIGNALS:
            signal.signal(number, interrupted)
        signal.setitimer(signal.ITIMER_REAL, activation.commands.remaining(270))
        result = activation.execute()
        signal.setitimer(signal.ITIMER_REAL, 0)
        print(json.dumps(result, separators=(",", ":")))
        return 0 if result["outcome"] == "committed" else 1
    except BaseException:
        published = activation is not None and activation.published
        print(json.dumps({"outcome": "manual_intervention_required" if published else "rejected",
                          "published": published, "stop": "unknown" if published else "not_attempted"}))
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    sys.exit(main())
