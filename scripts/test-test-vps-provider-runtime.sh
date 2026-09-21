#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

filesystem_only=false
previous_image=
target_image=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --filesystem-only)
      [ "$filesystem_only" = false ] || exit 2
      filesystem_only=true
      shift
      ;;
    --previous-image)
      [ "$#" -ge 2 ] && [ -z "$previous_image" ] || exit 2
      previous_image=$2
      shift 2
      ;;
    --target-image)
      [ "$#" -ge 2 ] && [ -z "$target_image" ] || exit 2
      target_image=$2
      shift 2
      ;;
    *)
      echo "usage: $0 --filesystem-only | --previous-image IMAGE@sha256:DIGEST --target-image IMAGE@sha256:DIGEST" >&2
      exit 2
      ;;
  esac
done

if [ "$filesystem_only" = false ]; then
  [[ "$previous_image" =~ ^.+@sha256:[0-9a-f]{64}$ ]]
  [[ "$target_image" =~ ^.+@sha256:[0-9a-f]{64}$ ]]
  [ "$previous_image" != "$target_image" ]
  command -v docker >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  docker info >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  previous_id=$(docker image inspect "$previous_image" --format '{{.Id}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  target_id=$(docker image inspect "$target_image" --format '{{.Id}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  [ "$previous_id" != "$target_id" ] || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

fixture=$(mktemp -d /var/lib/meet-provider-fixture.XXXXXX)
chmod 700 "$fixture"
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fixture_log="$fixture/output.log"
fixture_secret=RUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d
if ! python3 - "$fixture" >"$fixture_log" 2>&1 <<'PY'
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import struct
import sys
import tempfile

fixture = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "provider_helper", pathlib.Path("scripts/test-vps-provider-credential.py")
)
assert spec is not None and spec.loader is not None
helper = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helper
spec.loader.exec_module(helper)

parent = fixture / "credentials"
parent.mkdir(mode=0o700)
os.chown(parent, 0, 0)
source = fixture / "predecessor.json"
account = {
    "type": "service_account",
    "project_id": helper.EXPECTED_PROJECT,
    "client_email": "runtime-fixture@example.invalid",
    "client_id": "runtime-fixture-id",
    "private_key_id": "runtime-fixture-key",
    "private_key": "-----BEGIN PRIVATE KEY-----\nRUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d\n-----END PRIVATE KEY-----",
    "token_uri": "https://oauth2.example.invalid/token",
}
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)

helper.HOST_CREDENTIAL_PARENT = str(parent)
helper.HOST_CREDENTIAL_PATH = str(parent / "firebase-service-account.json")
helper.CONTAINER_CREDENTIAL_PATH = "/run/secrets/meet-firebase-service-account.json"
state = fixture / "state"
state.mkdir(mode=0o700)
os.chown(state, 0, 0)
marker = state / ".provider-transaction.current"

published_root = fixture / "published-states"
published_root.mkdir(mode=0o700)
os.chown(published_root, 0, 0)
helper._state_publish(str(published_root), "123456789-1", "final-deploy")
published_state = published_root / "123456789-1-final-deploy"
assert (published_state / helper.OWNER_MARKER).read_bytes() == helper._state_marker(
    "123456789-1", "final-deploy"
)
expect_collision = published_root / "456-1-final-deploy"
expect_collision.mkdir(mode=0o700)
os.chown(expect_collision, 0, 0)
try:
    helper._state_publish(str(published_root), "456-1", "final-deploy")
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication accepted an invalid run key")

def prepare_marker(run_key: str) -> None:
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "preparing",
                "providerEnabled": True,
                "durableDisposition": "none",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )

def cleanup_transaction(run_key: str, remove_destination: bool = True) -> None:
    marker.unlink(missing_ok=True)
    shutil.rmtree(parent / f".transaction-{run_key}", ignore_errors=True)
    if remove_destination:
        pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

def acl(entries: list[tuple[int, int, int]]) -> bytes:
    return struct.pack("<I", 2) + b"".join(
        struct.pack("<HHI", tag, permission, identifier)
        for tag, permission, identifier in entries
    )

def add_default_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_default",
        acl(
            [
                (1, 7, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 5, 0xFFFFFFFF),
                (16, 5, 0xFFFFFFFF),
                (32, 5, 0xFFFFFFFF),
            ]
        ),
    )

def add_private_access_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_access",
        acl(
            [
                (1, 0, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 0, 0xFFFFFFFF),
                (16, 0, 0xFFFFFFFF),
                (32, 0, 0xFFFFFFFF),
            ]
        ),
    )

def remove_acl(path: pathlib.Path, attribute: str) -> None:
    try:
        os.removexattr(path, attribute)
    except OSError as error:
        if error.errno != 61:
            raise

def expect_provider_error(action, category: str) -> None:
    try:
        action()
    except helper.ProviderError as error:
        assert error.category == category, error.category
    else:
        raise AssertionError(f"expected {category}")

def deny_unprivileged_read(path: pathlib.Path) -> None:
    child = os.fork()
    if child == 0:
        try:
            os.setgroups([])
            os.setgid(20002)
            os.setuid(20002)
            with path.open("rb"):
                os._exit(0)
        except OSError:
            os._exit(1)
    _, status = os.waitpid(child, 0)
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 1

def inspect(source_path: pathlib.Path) -> dict:
    return {
        "Config": {
            "Env": [
                "APP_PUSH_PROVIDER_ENABLED=true",
                "APP_PUSH_DISCOVERY_ENABLED=false",
                "APP_PUSH_DISPATCH_ENABLED=false",
                "APP_PUSH_DIAGNOSTIC_ENABLED=false",
                "APP_PUSH_MAINTENANCE_ENABLED=false",
                "APP_PUSH_PROJECT_ID=meeting-1d258",
                "APP_PUSH_CREDENTIALS_FILE=/run/secrets/meet-firebase-service-account.json",
            ]
        },
        "Mounts": [
            {"Type": "volume", "Destination": "/data/uploads"},
            {"Type": "tmpfs", "Destination": "/tmp"},
            {
                "Type": "bind",
                "Source": str(source_path),
                "Destination": "/run/secrets/meet-firebase-service-account.json",
                "RW": False,
            },
        ],
    }

predecessor = inspect(source)
add_default_acl(parent)
assert os.getxattr(parent, "system.posix_acl_default")
expect_provider_error(
    lambda: helper._acl_is_safe(str(parent)),
    "CREDENTIAL_INVALID",
)
expect_provider_error(
    lambda: helper._prepare(
        "default-acl-parent", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
remove_acl(parent, "system.posix_acl_default")
assert not (parent / ".transaction-default-acl-parent").exists()

prepare_marker("race-disappearance")
original_read_existing = helper._read_existing
race_removed = False

def remove_destination_before_read(path: str, source: bool = False):
    global race_removed
    if path == helper.HOST_CREDENTIAL_PATH and not source and not race_removed:
        race_removed = True
        pathlib.Path(path).unlink()
    return original_read_existing(path, source=source)

helper._read_existing = remove_destination_before_read
expect_provider_error(
    lambda: helper._prepare(
        "race-disappearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
helper._read_existing = original_read_existing
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-disappearance" / "snapshot").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-disappearance")

prepare_marker("race-appearance")
original_link = helper.os.link

def create_raced_destination(source_path: str, destination_path: str, **kwargs):
    fd = os.open(destination_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o440)
    try:
        os.write(fd, source.read_bytes())
        os.fchown(fd, 0, 10001)
        os.fchmod(fd, 0o440)
    finally:
        os.close(fd)
    raise FileExistsError(17, "destination appeared", destination_path)

helper.os.link = create_raced_destination
expect_provider_error(
    lambda: helper._prepare(
        "race-appearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "DURABLE_CONFLICT",
)
helper.os.link = original_link
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-appearance" / "publication").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-appearance")

prepare_marker("source-drift")
helper._prepare("source-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "source-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
changed_account = dict(account)
changed_account["client_id"] = "runtime-fixture-changed-id"
source.write_text(json.dumps(changed_account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
expect_provider_error(
    lambda: helper._verify(
        "source-drift",
        "",
        json.dumps([predecessor, predecessor]).encode(),
        "predecessor",
        str(state),
    ),
    "CREDENTIAL_CHANGED",
)
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
cleanup_transaction("source-drift")

prepare_marker("witness-removal")
helper._prepare("witness-removal", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-removal",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
(parent / ".transaction-witness-removal" / "publication").unlink()
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
expect_provider_error(
    lambda: helper._verify(
        "witness-removal",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("witness-removal")

prepare_marker("marker-drift")
helper._prepare("marker-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "marker-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
expect_provider_error(
    lambda: helper._verify(
        "marker-drift",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("marker-drift")

prepare_marker("created")
helper._prepare("created", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "created"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "created",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
deny_unprivileged_read(parent / ".transaction-created" / "snapshot")
deny_unprivileged_read(parent / ".transaction-created" / "identity.json")
add_default_acl(parent / ".transaction-created")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created", "system.posix_acl_default")
add_private_access_acl(parent / ".transaction-created" / "snapshot")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created" / "snapshot", "system.posix_acl_access")
os.chmod(parent / ".transaction-created" / "snapshot", 0o600)
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
helper._verify(
    "created",
    "",
    json.dumps([predecessor, candidate]).encode(),
    "candidate",
)
helper._finish("created", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert not (parent / ".transaction-created").exists()

prepare_marker("reused")
helper._prepare("reused", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "reused"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "reused",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "reused",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("reused", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()

os.unlink(helper.HOST_CREDENTIAL_PATH)
prepare_marker("rollback")
helper._prepare("rollback", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "rollback",
            "phase": "rolling-back",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("rollback", str(state), "", "rolled-back", json.dumps(predecessor).encode())
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
marker.unlink()

prepare_marker("witness-tamper")
helper._prepare("witness-tamper", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-tamper",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
os.chmod(parent / ".transaction-witness-tamper" / "publication", 0o600)
try:
    helper._finish(
        "witness-tamper",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("tampered publication witness was accepted")
cleanup_transaction("witness-tamper")

def prepare_finalizing(run_key: str) -> dict:
    prepare_marker(run_key)
    helper._prepare(run_key, str(state), "", json.dumps(predecessor).encode())
    marker.unlink()
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "finalizing",
                "providerEnabled": True,
                "durableDisposition": "created",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )
    return inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))

def finish_and_remove(run_key: str, candidate: dict) -> None:
    helper._finish(
        run_key,
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
    marker.unlink()
    assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
    cleanup_transaction(run_key)

candidate = prepare_finalizing("cleanup-hard-link")
hard_link = parent / "operator-hard-link"
os.link(helper.HOST_CREDENTIAL_PATH, hard_link)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-hard-link",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert hard_link.exists()
hard_link.unlink()
cleanup_transaction("cleanup-hard-link")

candidate = prepare_finalizing("cleanup-metadata")
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o600)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-metadata",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o440)
cleanup_transaction("cleanup-metadata")

candidate = prepare_finalizing("cleanup-replacement")
os.unlink(helper.HOST_CREDENTIAL_PATH)
replacement = parent / "operator-replacement"
replacement.write_bytes(b"operator replacement")
os.chown(replacement, 0, 10001)
os.chmod(replacement, 0o440)
os.rename(replacement, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-replacement",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).read_bytes() == b"operator replacement"
cleanup_transaction("cleanup-replacement")

candidate = prepare_finalizing("cleanup-symlink")
os.unlink(helper.HOST_CREDENTIAL_PATH)
os.symlink(source, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-symlink",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).is_symlink()
cleanup_transaction("cleanup-symlink")

candidate = prepare_finalizing("cleanup-unlink-race")
original_unlink = helper.os.unlink

def reject_descriptor_unlink(path, **kwargs):
    if kwargs.get("dir_fd") is not None:
        raise OSError(11, "operator replacement race")
    return original_unlink(path, **kwargs)

helper.os.unlink = reject_descriptor_unlink
expect_provider_error(
    lambda: helper._finish(
        "cleanup-unlink-race",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
helper.os.unlink = original_unlink
finish_and_remove("cleanup-unlink-race", candidate)

for child in ("identity.json", "snapshot", "publication"):
    run_key = "cleanup-same-metadata-" + child.replace(".", "-")
    candidate = prepare_finalizing(run_key)
    tx = parent / (".transaction-" + run_key)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_transaction_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("replacement-" + run_key)
            data = (tx / child).read_bytes()
            info = os.stat(tx / child, follow_symlinks=False)
            os.unlink(tx / child)
            replacement.write_bytes(data)
            os.chown(replacement, info.st_uid, info.st_gid)
            os.chmod(replacement, stat.S_IMODE(info.st_mode))
            os.rename(replacement, tx / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_transaction_child
    expect_provider_error(
        lambda: helper._finish(
            run_key,
            str(state),
            "",
            "committed",
            json.dumps(candidate).encode(),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    assert (tx / child).exists()
    assert marker.exists()
    shutil.rmtree(tx)
    marker.unlink()
    pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

retention_root = fixture / "retention-root"
retention_root.mkdir(mode=0o700)
os.chown(retention_root, 0, 0)
for child in sorted(helper.RETENTION_CHILDREN - {"provider-owner.json", "terminal.json"}):
    retention_state = retention_root / "77-1-final-deploy"
    retention_state.mkdir(mode=0o700)
    os.chown(retention_state, 0, 0)
    for state_child in helper.RETENTION_CHILDREN:
        path = retention_state / state_child
        if state_child == "provider-owner.json":
            path.write_bytes(
                helper._state_marker("77-1", "final-deploy")
            )
        elif state_child == "terminal.json":
            path.write_bytes(
                b'{"schemaVersion":1,"runKey":"77-1","outcome":"committed","providerEnabled":false}'
            )
        else:
            path.write_bytes(("retention-" + state_child).encode())
        os.chown(path, 0, 0)
        os.chmod(path, 0o600)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_retention_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("retention-replacement-" + child.replace(".", "-"))
            data = (retention_state / child).read_bytes()
            os.unlink(retention_state / child)
            replacement.write_bytes(data)
            os.chown(replacement, 0, 0)
            os.chmod(replacement, 0o600)
            os.rename(replacement, retention_state / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_retention_child
    expect_provider_error(
        lambda: helper._retention_delete(
            str(retention_root),
            str(retention_state),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    quarantine = retention_root / ".provider-state.77-1-final-deploy.tmp"
    assert not retention_state.exists()
    assert quarantine.exists()
    shutil.rmtree(quarantine)
PY
then
  echo "provider runtime fixture failed" >&2
  sed -n '1,160p' "$fixture_log" >&2
  exit 1
fi
! grep -Fq "$fixture_secret" "$fixture_log" ||
  { echo "provider runtime fixture leaked private credential bytes" >&2; exit 1; }

python3 -B scripts/test-test-vps-provider-credential.py
echo "provider filesystem fixture passed: ACL/default-ACL rejection, unprivileged private-read denial, bounded parsing, no-follow publication, reuse and rollback cleanup; secret scan passed"
