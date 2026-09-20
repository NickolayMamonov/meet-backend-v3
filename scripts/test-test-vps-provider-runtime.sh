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

helper._prepare("created", str(state), "", json.dumps(predecessor).encode())
marker = state / ".provider-transaction.current"
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

helper._prepare("reused", str(state), "", json.dumps(predecessor).encode())
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
helper._prepare("rollback", str(state), "", json.dumps(predecessor).encode())
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

helper._prepare("witness-tamper", str(state), "", json.dumps(predecessor).encode())
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
