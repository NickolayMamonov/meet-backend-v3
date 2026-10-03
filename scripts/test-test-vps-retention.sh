#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

prerequisite_missing() {
  echo "PREREQUISITE_MISSING" >&2
  exit 77
}

if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

if [ "${1:-}" != --fixture-parent ] ||
  { [ "$#" -ne 2 ] && [ "$#" -ne 6 ]; }; then
  echo "PREREQUISITE_MISSING: explicit fixture parent required" >&2
  exit 77
fi
fixture_parent=$2
[ "$fixture_parent" = /fixture ] ||
  { echo "PREREQUISITE_MISSING: fixture parent must be /fixture" >&2; exit 77; }
if [ "$#" -eq 6 ] && [ "${3:-}" != --check-fixed-roots ]; then
  echo "PREREQUISITE_MISSING: arbitrary fixture-root arguments are forbidden" >&2
  exit 77
fi
[ -d "$fixture_parent" ] && [ ! -L "$fixture_parent" ] ||
  prerequisite_missing
[ "$(stat -c '%u:%a' "$fixture_parent" 2>/dev/null)" = 0:700 ] ||
  prerequisite_missing
fixture_mount=$(findmnt -n -o TARGET,FSTYPE --target "$fixture_parent" 2>/dev/null) ||
  prerequisite_missing
[ "$fixture_mount" = $'/fixture tmpfs' ] || prerequisite_missing
[ "$(findmnt -R -n -o TARGET "$fixture_parent" 2>/dev/null)" = /fixture ] ||
  prerequisite_missing
python3 - "$fixture_parent" <<'PY' || prerequisite_missing
import errno
import os
import stat
import sys

for path in ("/", sys.argv[1]):
    info = os.lstat(path)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise SystemExit(1)
    for attribute in (
        "system.posix_acl_access",
        "system.posix_acl_default",
    ):
        try:
            os.getxattr(path, attribute, follow_symlinks=False)
        except OSError as error:
            if error.errno == errno.ENODATA:
                continue
            raise SystemExit(1)
        raise SystemExit(1)
PY
fixture_parent_identity=$(stat -c '%d:%i:%f:%u:%g' "$fixture_parent")

fixture_root=
fixture_root_identity=
sentinel_root=
sentinel_root_identity=
state_root=
production_root=
production_runtime_root=
fake_bin=
remote_script=
remote_script_digest=
created_fixed_roots=()
created_fixed_root_identities=()
completed_cases=()
owned_root_recorder=record_created_root
fixed_root_prefix='/var/lib/meet-'
root_identity() {
  stat -c '%d:%i:%f:%u:%g' -- "$1"
}
create_owned_root() {
  local path=$1
  if ! mkdir -m 700 -- "$path" 2>/dev/null; then
    prerequisite_missing
  fi
  "$owned_root_recorder" "$path"
  chown 0:0 -- "$path" 2>/dev/null || prerequisite_missing
  chmod 700 -- "$path" 2>/dev/null || prerequisite_missing
}
remove_owned_root() {
  local path=$1
  local expected_identity=$2
  local require_empty=${3:-false}
  [ -e "$path" ] || [ -L "$path" ] || return 0
  timeout 30s python3 - "$path" "$expected_identity" "$require_empty" <<'PY'
import fcntl
import os
import stat
import sys

path, expected, require_empty = sys.argv[1:]


def identity(info):
    return f"{info.st_dev}:{info.st_ino}:{info.st_mode:x}:{info.st_uid}:{info.st_gid}"


def same_inode(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def fail():
    raise SystemExit(1)


parent_path, name = os.path.split(path)
parent_fd = os.open(
    parent_path or "/",
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
)
try:
    fcntl.flock(parent_fd, fcntl.LOCK_EX)
    root_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if (
        not stat.S_ISDIR(root_info.st_mode)
        or identity(root_info) != expected
    ):
        fail()
    root_fd = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_fd,
    )
    try:
        opened = os.fstat(root_fd)
        if not same_inode(opened, root_info) or identity(opened) != expected:
            fail()
        entries = list(os.scandir(f"/proc/self/fd/{root_fd}"))
        if require_empty == "true" and entries:
            fail()

        def remove_contents(directory_fd, directory_entries):
            for entry in directory_entries:
                child_info = os.stat(
                    entry.name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if stat.S_ISDIR(child_info.st_mode):
                    child_fd = os.open(
                        entry.name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=directory_fd,
                    )
                    try:
                        opened_child = os.fstat(child_fd)
                        if not same_inode(opened_child, child_info):
                            fail()
                        remove_contents(
                            child_fd,
                            list(os.scandir(f"/proc/self/fd/{child_fd}")),
                        )
                        current_child = os.stat(
                            entry.name,
                            dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        if not same_inode(current_child, opened_child):
                            fail()
                    finally:
                        os.close(child_fd)
                    os.rmdir(entry.name, dir_fd=directory_fd)
                else:
                    current_child = os.stat(
                        entry.name,
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                    if not same_inode(current_child, child_info):
                        fail()
                    os.unlink(entry.name, dir_fd=directory_fd)

        remove_contents(root_fd, entries)
        if next(os.scandir(f"/proc/self/fd/{root_fd}"), None) is not None:
            fail()
        current_root = os.stat(
            name,
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
        if not same_inode(current_root, opened) or identity(current_root) != expected:
            fail()
    finally:
        os.close(root_fd)
    current_root = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if identity(current_root) != expected:
        fail()
    os.rmdir(name, dir_fd=parent_fd)
finally:
    os.close(parent_fd)
PY
}
record_created_root() {
  local path=$1
  local identity
  [ -d "$path" ] && [ ! -L "$path" ] || prerequisite_missing
  identity=$(root_identity "$path" 2>/dev/null) || prerequisite_missing
  created_fixed_roots+=("$path")
  created_fixed_root_identities+=("$identity")
}
record_case() {
  local case_id=$1 existing
  for existing in "${completed_cases[@]}"; do
    [ "$existing" != "$case_id" ] || {
      echo "RETENTION_PROOF_DENIED" >&2
      exit 1
    }
  done
  completed_cases+=("$case_id")
}
emit_summary() {
  RETENTION_PROOF_CASES=$(printf '%s\n' "${completed_cases[@]}") \
    RETENTION_PROOF_BLOCK_SHA256=$remote_script_digest \
    python3 -B - <<'PY'
import json
import os
import re
import sys

required = (
    "eligible-owned-terminal-states-removed",
    "active-protected-legacy-unknown-preserved",
    "all-service-mount-references-respected",
    "current-tooling-deleted-last",
    "repeat-run-is-idempotent",
    "only-owned-roots-removed",
    "outside-sentinel-preserved",
    "missing-or-unsafe-root-denied",
    "symlink-hardlink-prefix-collision-denied",
    "top-level-nested-replacement-preserved",
    "malformed-helper-inspection-denied",
    "smtp-transaction-lock-contention-denied",
    "timeout-hup-int-term-denied",
    "cleanup-failure-overrides-pass",
)
cases = os.environ.get("RETENTION_PROOF_CASES", "").splitlines()
if len(cases) != len(required) or set(cases) != set(required):
    raise SystemExit(1)
source = os.environ.get("RETENTION_PROOF_SOURCE_SHA", "")
image = os.environ.get("RETENTION_PROOF_IMAGE_DIGEST", "")
toolchain = os.environ.get("RETENTION_PROOF_TOOLCHAIN_SHA256", "")
block = os.environ.get("RETENTION_PROOF_BLOCK_SHA256", "")
if not re.fullmatch(r"[0-9a-f]{40}", source):
    raise SystemExit(1)
if not re.fullmatch(r"sha256:[0-9a-f]{64}", image):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}", toolchain):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9a-f]{64}", block):
    raise SystemExit(1)
summary = {
    "schemaVersion": 1,
    "outcome": "passed",
    "sourceSha": source,
    "planSha256": "a7cf15f7bf1ff2860a3e3716ee986f0543bedac339469756a74ed8830047ce2a",
    "imageDigest": image,
    "toolchainSha256": toolchain,
    "extractedRetentionBlockSha256": block,
    "cases": [{"id": case_id, "outcome": "passed"} for case_id in required],
    "selectiveCleanup": True,
    "outsideSentinel": True,
}
if os.environ.get("RETENTION_PROOF_PLAN_SHA256") != summary["planSha256"]:
    raise SystemExit(1)
print("RETENTION_FIXTURE_SUMMARY:" + json.dumps(
    summary, sort_keys=True, separators=(",", ":"), ensure_ascii=True
))
PY
}
fixture_install_dir() {
  install -d -m "$1" -- "$2" 2>/dev/null || prerequisite_missing
}
fixture_write() {
  local path=$1
  local mode=$2
  cat >"$path" 2>/dev/null || prerequisite_missing
  chmod "$mode" "$path" 2>/dev/null || prerequisite_missing
}
fixture_append() {
  cat >>"$1" 2>/dev/null || prerequisite_missing
}
fixture_copy() {
  cp -- "$1" "$2" 2>/dev/null || prerequisite_missing
}
fixture_touch() {
  touch "$@" 2>/dev/null || prerequisite_missing
}
assert_replacement_rejected() {
  local label=$1
  local root expected original status
  root=$(mktemp -d "$fixture_parent/owned-root.XXXXXX") ||
    prerequisite_missing
  expected=$(root_identity "$root" 2>/dev/null) || prerequisite_missing
  original="$root.original"
  [ ! -e "$original" ] && [ ! -L "$original" ] || prerequisite_missing
  mv -- "$root" "$original" || prerequisite_missing
  mkdir -m 700 -- "$root" || prerequisite_missing
  printf 'replacement-%s\n' "$label" >"$root/sentinel" ||
    prerequisite_missing
  set +e
  remove_owned_root "$root" "$expected"
  status=$?
  set -e
  [ "$status" -ne 0 ]
  grep -Fxq "replacement-$label" "$root/sentinel"
  timeout 30s rm -r -- "$root"
  remove_owned_root "$original" "$expected"
}
remove_parent_after_owned_children() {
  local child_status=$1
  local parent=$2
  local expected=$3
  [ "$child_status" -eq 0 ] || return 1
  [ -n "$parent" ] || return 0
  remove_owned_root "$parent" "$expected"
}
assert_nested_replacement_preserved() {
  local parent child expected_parent expected_child original_child status actual
  parent=$(mktemp -d "$fixture_parent/nested-parent.XXXXXX") ||
    prerequisite_missing
  expected_parent=$(root_identity "$parent" 2>/dev/null) ||
    prerequisite_missing
  child="$parent/nested"
  mkdir -m 700 -- "$child" || prerequisite_missing
  expected_child=$(root_identity "$child" 2>/dev/null) ||
    prerequisite_missing
  original_child="$child.original"
  mv -- "$child" "$original_child" || prerequisite_missing
  mkdir -m 700 -- "$child" || prerequisite_missing
  printf 'nested-replacement\n' >"$child/sentinel" || prerequisite_missing
  actual=$(root_identity "$child" 2>/dev/null) || prerequisite_missing
  status=0
  [ "$actual" = "$expected_child" ] || status=1
  set +e
  remove_parent_after_owned_children "$status" "$parent" "$expected_parent"
  status=$?
  set -e
  [ "$status" -ne 0 ]
  grep -Fxq 'nested-replacement' "$child/sentinel"
  timeout 30s rm -r -- "$child"
  remove_owned_root "$parent" "$expected_parent"
}
cleanup() {
  local status=$?
  local cleanup_status=0
  local index path expected actual
  trap - EXIT
  for index in "${!created_fixed_roots[@]}"; do
    path=${created_fixed_roots[$index]}
    expected=${created_fixed_root_identities[$index]}
    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -d "$path" ] || [ -L "$path" ] ||
        ! actual=$(root_identity "$path" 2>/dev/null) ||
        [ "$actual" != "$expected" ]; then
        cleanup_status=1
      else
        remove_owned_root "$path" "$expected" || cleanup_status=1
      fi
    fi
  done
  if [ -n "$sentinel_root" ]; then
    grep -Fxq 'outside-fixture' "$sentinel_root/sentinel" || status=1
  fi
  if ! remove_parent_after_owned_children "$cleanup_status" \
    "$fixture_root" "$fixture_root_identity"; then
    cleanup_status=1
  fi
  if [ -n "$sentinel_root" ] &&
    { [ -e "$sentinel_root" ] || [ -L "$sentinel_root" ]; }; then
    remove_owned_root "$sentinel_root" "$sentinel_root_identity" ||
      cleanup_status=1
  fi
  [ "$(stat -c '%d:%i:%f:%u:%g' "$fixture_parent" 2>/dev/null || true)" = \
    "$fixture_parent_identity" ] || cleanup_status=1
  [ "$status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] || status=1
  if [ "$status" -eq 0 ]; then
    emit_summary || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

if [ "${3:-}" = --check-fixed-roots ]; then
  [ "$#" -eq 6 ] || exit 77
  for path in "${@:4}"; do
    [[ "$path" == "$fixture_parent"/* ]] || exit 77
    case "$path" in
      *'/../'*|*'/./'*|*$'\n'*|*$'\r'*) exit 77 ;;
    esac
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "PREREQUISITE_MISSING: fixture root already exists" >&2
      exit 77
    fi
  done
  exit 0
fi

# All application-shaped state remains synthetic and fixture-local.
fixture_root=$(mktemp -d "$fixture_parent/run.XXXXXX" 2>/dev/null) ||
  prerequisite_missing
chmod 700 "$fixture_root" 2>/dev/null || prerequisite_missing
fixture_root_identity=$(root_identity "$fixture_root" 2>/dev/null) ||
  prerequisite_missing
sentinel_root=$(mktemp -d "$fixture_parent/sentinel.XXXXXX" 2>/dev/null) ||
  prerequisite_missing
sentinel_root_identity=$(root_identity "$sentinel_root" 2>/dev/null) ||
  prerequisite_missing
state_root="$fixture_root/state"
production_root="$fixture_root/production"
production_runtime_root="$fixture_root/production-runtime"
fake_bin="$fixture_root/bin"
remote_script="$fixture_root/retention-remote.sh"
printf 'outside-fixture\n' >"$sentinel_root/sentinel"
if [ "${RETENTION_PROOF_INJECT_CLEANUP_FAILURE:-}" = 1 ]; then
  mv -- "$fixture_root" "$fixture_parent/cleanup-original" ||
    prerequisite_missing
  ln -s -- "$sentinel_root" "$fixture_root" || prerequisite_missing
  exit 0
fi
fixed_root_prefix='/var/lib/meet-'
if grep -Fq "${fixed_root_prefix}production" "${BASH_SOURCE[0]}" ||
  grep -Fq "${fixed_root_prefix}test-vps-deploy" "${BASH_SOURCE[0]}"; then
  echo "RECOVERY_REQUIRED" >&2
  exit 1
fi

for path in "$state_root" "$production_root" "$production_runtime_root"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "PREREQUISITE_MISSING: fixture root already exists" >&2
    exit 77
  fi
done

assert_replacement_rejected fixture-root
assert_replacement_rejected sentinel-root
assert_nested_replacement_preserved
record_case top-level-nested-replacement-preserved

set +e
unsafe_parent_output=$(bash "$0" --fixture-parent '/fixture/../fixture' 2>&1)
unsafe_parent_status=$?
set -e
[ "$unsafe_parent_status" -eq 77 ]
grep -Fq 'explicit fixture parent required' <<<"$unsafe_parent_output"
record_case missing-or-unsafe-root-denied

set +e
cleanup_failure_output=$(RETENTION_PROOF_INJECT_CLEANUP_FAILURE=1 \
  bash "$0" --fixture-parent "$fixture_parent" 2>&1)
cleanup_failure_status=$?
set -e
[ "$cleanup_failure_status" -eq 1 ]
! grep -Fq 'RETENTION_FIXTURE_SUMMARY:' <<<"$cleanup_failure_output"
record_case cleanup-failure-overrides-pass

(
  set -euo pipefail
  probe_roots=()
  probe_root_identities=()
  record_probe_root() {
    local path=$1
    local identity
    [ -d "$path" ] && [ ! -L "$path" ] || prerequisite_missing
    identity=$(root_identity "$path" 2>/dev/null) || prerequisite_missing
    probe_roots+=("$path")
    probe_root_identities+=("$identity")
  }
  probe_cleanup() {
    local index path expected actual
    for index in "${!probe_roots[@]}"; do
      path=${probe_roots[$index]}
      expected=${probe_root_identities[$index]}
      if [ -e "$path" ] || [ -L "$path" ]; then
        actual=$(root_identity "$path" 2>/dev/null) || exit 1
        [ "$actual" = "$expected" ] || exit 1
        remove_owned_root "$path" "$expected" || exit 1
      fi
    done
  }
  trap probe_cleanup EXIT
  owned_root_recorder=record_probe_root
  for path in "$state_root" "$production_root" "$production_runtime_root"; do
    create_owned_root "$path"
    fixture_write "$path/sentinel" 600 <<'EOF'
fixed-root-sentinel
EOF
  done
  fixed_before=$(
    for path in "$state_root" "$production_root" "$production_runtime_root"; do
      find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n'
      find "$path" -xdev -type f -exec sha256sum {} +
    done | sort
  )
  set +e
  fixed_output=$(bash "$0" --fixture-parent "$fixture_parent" \
    --check-fixed-roots \
    "$state_root" "$production_root" "$production_runtime_root" 2>&1)
  fixed_status=$?
  set -e
  [ "$fixed_status" -eq 77 ]
  grep -Fq 'fixture root already exists' <<<"$fixed_output"
  test "$fixed_before" = "$(
    for path in "$state_root" "$production_root" "$production_runtime_root"; do
      find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n'
      find "$path" -xdev -type f -exec sha256sum {} +
    done | sort
  )"
)

legacy_names=(
  31885558214-1-rollback-drill
  31886011287-1-rollback-drill
  31886542144-1-final-deploy
  31886542144-1-rollback-drill
  31887546557-1-final-deploy
  33076843662-1-final-deploy
  33076843662-1-rollback-drill
  35471104657-1-rollback-drill
)
legacy_digest() {
  local name path
  for name in "${legacy_names[@]}"; do
    path="$state_root/$name"
    find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' | sort
    find "$path" -xdev -type f -exec sha256sum {} +
  done
}
write_owner_marker() {
  local state=$1
  local name=${state##*/}
  local run_key=${name%-final-deploy}
  [ "$run_key" = "$name" ] && run_key=${name%-rollback-drill}
  local state_kind=${name#"$run_key"-}
  fixture_write "$state/provider-owner.json" 600 <<EOF
{"schemaVersion":1,"owner":"meet-test-vps-provider","runKey":"$run_key","stateKind":"$state_kind"}
EOF
}

fixture_install_dir 700 "$fake_bin"
create_owned_root "$state_root"
create_owned_root "$production_root"
create_owned_root "$production_runtime_root"
owned_root_recorder=record_created_root
fixture_write "$production_root/.env.production" 600 <<'EOF'
fixture
EOF
fixture_write "$production_root/docker-compose.production.yml" 600 <<'EOF'
services:
  backend:
    image: fixture
EOF
fixture_write "$production_runtime_root/active-compose.yml" 600 <<'EOF'
services:
  backend:
    image: fixture
EOF
fixture_write "$production_runtime_root/active-runtime.override.yml" 600 <<'EOF'
services:
  backend:
    healthcheck:
      test: ["CMD", "true"]
EOF

legacy_index=0
for name in "${legacy_names[@]}"; do
  fixture_install_dir 700 "$state_root/$name"
  fixture_write "$state_root/$name/opaque.bin" 600 <<EOF
legacy synthetic bytes: $name
EOF
  fixture_touch -d "@$((1700000000 + legacy_index)).123456789" \
    "$state_root/$name/opaque.bin" "$state_root/$name"
  legacy_index=$((legacy_index + 1))
done
legacy_before=$(legacy_digest)
grep -Eq '\|[0-9]+\.[0-9]{9,}$' <<<"$legacy_before"
set +e
legacy_delete_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$state_root/${legacy_names[0]}" 2>&1)
legacy_delete_status=$?
set -e
[ "$legacy_delete_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$legacy_delete_output"
test "$legacy_before" = "$(legacy_digest)"

fixture_write "$fake_bin/docker" 700 <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
fixture_state_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../state" && pwd)
case "${1:-}" in
  ps)
    if [ -n "${RETENTION_SIGNAL_READY_FIFO:-}" ]; then
      printf 'ready\n' >"$RETENTION_SIGNAL_READY_FIFO"
      IFS= read -r signal_release <"$RETENTION_SIGNAL_RELEASE_FIFO"
      [ "$signal_release" = RELEASE ] || exit 88
    fi
    printf 'fixture-backend\nfixture-provider\n'
    ;;
  inspect)
    case "${2:-}" in
      fixture-backend)
        if [ "${RETENTION_MALFORMED_DOCKER:-}" = 1 ]; then
          printf 'not-json\n'
          exit 0
        fi
        printf '[{"Type":"volume","Name":"uploads","Destination":"/data/uploads"}]\n'
        ;;
      fixture-provider)
        printf '[{"Type":"bind","Source":"%s/12-1-final-deploy/provider-runtime","Destination":"/run/provider"}]\n' \
          "$fixture_state_root"
        ;;
      *)
        printf '{}\n'
        ;;
    esac
    ;;
  compose)
    case " $* " in
      *"/12-1-final-deploy/"*)
        printf '{"services":{"backend":{"volumes":[{"type":"bind","source":"%s/12-1-final-deploy/protected-input","target":"/protected"}]}}}\n' \
          "$fixture_state_root"
        ;;
      *)
        printf '{"services":{"backend":{"volumes":[]}}}\n'
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
FAKE_DOCKER

remote_content=$(awk '
  /name: Apply bounded test-VPS deployment retention/ { section=1 }
  section && /<<'\''REMOTE'\''/ { inside=1; next }
  inside && /^          REMOTE$/ { exit }
  inside { sub(/^          /, ""); print }
' .github/workflows/deploy-test-vps.yml 2>/dev/null) ||
  prerequisite_missing
block_markers=$(grep -Fc \
  'name: Apply bounded test-VPS deployment retention' \
  .github/workflows/deploy-test-vps.yml) || prerequisite_missing
remote_markers=$(awk '
  /name: Apply bounded test-VPS deployment retention/ { section=1 }
  section && /<<'\''REMOTE'\''/ { count++ }
  END { print count + 0 }
' .github/workflows/deploy-test-vps.yml) || prerequisite_missing
[ "$block_markers" -eq 1 ] && [ "$remote_markers" -eq 1 ] ||
  { echo "RECOVERY_REQUIRED" >&2; exit 1; }
fixture_write "$remote_script" 700 <<<"$remote_content"
remote_script_digest=$(sha256sum "$remote_script" | cut -d ' ' -f 1) ||
  prerequisite_missing
[ "$remote_script_digest" = \
  7cdc12b1f0fc3a5252686bbccaf74bac04c433f42061432d1e9d3749a82934f3 ] ||
  { echo "RECOVERY_REQUIRED" >&2; exit 1; }
for signature in \
  'exec 9>"$state_root/.deploy.lock"' \
  'if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]' \
  'delete_owned_state "$path"' \
  'tooling_removed=0' \
  'retention=applied'; do
  grep -Fq "$signature" "$remote_script" ||
    { echo "RECOVERY_REQUIRED" >&2; exit 1; }
done
fixture_touch "$state_root/.deploy.lock"
signal_before=$(find "$state_root" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' |
  sort)
python3 - "$remote_script" "$production_root" "$production_runtime_root" \
  "$state_root" "$fake_bin" "$fixture_root" <<'PY'
import os
import selectors
import signal
import subprocess
import sys
from pathlib import Path

remote, config_root, runtime_root, state_root, fake_bin, fixture_root = sys.argv[1:]
for name, sig in (
    ("hup", signal.SIGHUP),
    ("int", signal.SIGINT),
    ("term", signal.SIGTERM),
):
    control = Path(fixture_root) / ("signal-" + name)
    control.mkdir(mode=0o700)
    ready = control / "ready"
    release = control / "release"
    os.mkfifo(ready, 0o600)
    os.mkfifo(release, 0o600)
    ready_fd = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
    release_fd = os.open(release, os.O_RDWR | os.O_NONBLOCK)
    environment = dict(os.environ)
    environment.update(
        {
            "PATH": fake_bin + os.pathsep + environment.get("PATH", ""),
            "FIXTURE_STATE_ROOT": state_root,
            "RETENTION_SIGNAL_READY_FIFO": str(ready),
            "RETENTION_SIGNAL_RELEASE_FIFO": str(release),
        }
    )
    process = subprocess.Popen(
        [
            "bash",
            remote,
            config_root,
            "1",
            "1",
            str(Path(config_root) / ".signal-tooling"),
            state_root,
            runtime_root,
        ],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    selector = selectors.DefaultSelector()
    selector.register(ready_fd, selectors.EVENT_READ)
    events = selector.select(35)
    selector.close()
    if not events or os.read(ready_fd, 64) != b"ready\n":
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise SystemExit(1)
    os.killpg(process.pid, sig)
    os.write(release_fd, b"ABORT\n")
    try:
        stdout, stderr = process.communicate(timeout=35)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise SystemExit(1)
    if process.returncode == 0:
        raise SystemExit(1)
    if b"RETENTION_FIXTURE_SUMMARY:" in stdout + stderr:
        raise SystemExit(1)
    os.close(ready_fd)
    os.close(release_fd)
    ready.unlink()
    release.unlink()
    control.rmdir()
PY
test "$signal_before" = "$(
  find "$state_root" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' | sort
)"
set +e
unsafe_output=$(bash "$remote_script" "$production_root" 1 1 \
  "$production_root/.missing-tooling" "$state_root/../unsafe" \
  "$production_runtime_root" 2>&1)
unsafe_status=$?
set -e
[ "$unsafe_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$unsafe_output"

for index in $(seq 1 12); do
  state="$state_root/${index}-1-final-deploy"
  fixture_install_dir 700 "$state"
  fixture_write "$state/terminal.json" 600 <<EOF
{"schemaVersion":1,"runKey":"$index-1","outcome":"committed","providerEnabled":false}
EOF
  write_owner_marker "$state"
  fixture_touch -d "@$((1800000000 - index)).123456789" "$state"
done
owned_digest() {
  local path=$1
  find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' | sort
  find "$path" -xdev -type f -exec sha256sum {} +
}
protected_state="$state_root/1-1-final-deploy"
protected_before=$(owned_digest "$protected_state")
set +e
protected_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$protected_state" \
  --protected-state "$protected_state" 2>&1)
protected_status=$?
set -e
[ "$protected_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$protected_output"
[ -d "$protected_state" ]
[ ! -e "$state_root/.provider-state.1-1-final-deploy.tmp" ]
test "$protected_before" = "$(owned_digest "$protected_state")"
smtp_guard="$state_root/2-1-final-deploy"
smtp_before=$(owned_digest "$smtp_guard")
smtp_quarantine="$state_root/.provider-state.smtp-guard.tmp"
fixture_install_dir 700 "$smtp_quarantine"
fixture_write "$smtp_quarantine/sentinel" 600 <<'EOF'
pre-existing smtp quarantine
EOF
smtp_quarantine_before=$(owned_digest "$smtp_quarantine")
ln -s "$state_root/missing-smtp-transaction-target" \
  "$state_root/.smtp-transaction.current"
set +e
smtp_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$smtp_guard" 2>&1)
smtp_status=$?
set -e
[ "$smtp_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$smtp_output"
[ -L "$state_root/.smtp-transaction.current" ]
[ -d "$smtp_guard" ]
test "$smtp_before" = "$(owned_digest "$smtp_guard")"
test "$smtp_quarantine_before" = "$(owned_digest "$smtp_quarantine")"
rm -f -- "$state_root/.smtp-transaction.current"
rm -r -- "$smtp_quarantine"
fixture_install_dir 700 "$state_root/12-1-final-deploy/protected-input"
fixture_install_dir 700 "$state_root/12-1-final-deploy/provider-runtime"
fixture_write "$state_root/12-1-final-deploy/target-runtime.override.yml" 600 <<'EOF'
services:
  backend:
    volumes: []
EOF
fixture_install_dir 700 "$state_root/12-1-final-deploy-shadow"
fixture_install_dir 700 "$state_root/14-1-final-deploy"
fixture_write "$state_root/14-1-final-deploy/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"14-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$state_root/14-1-final-deploy"
fixture_write "$state_root/14-1-final-deploy/unknown.txt" 600 <<'EOF'
unknown
EOF
fixture_touch -d '@1799999980.123456789' "$state_root/14-1-final-deploy"
fixture_install_dir 700 "$state_root/17-1-final-deploy"
fixture_write "$state_root/17-1-final-deploy/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"17-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$state_root/17-1-final-deploy"
fixture_write "$state_root/17-1-final-deploy/unknown-before-race.txt" 600 <<'EOF'
unknown-before-race
EOF
fixture_touch -d '@1799999970.123456789' "$state_root/17-1-final-deploy"

tooling_root="$production_root/.test-vps-tooling-1-1"
fixture_install_dir 700 "$tooling_root/scripts"
fixture_copy scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
fixture_write "$tooling_root/scripts/test-vps-provider-credential.py" 700 <<EOF
#!/usr/bin/env python3
import pathlib
import runpy
import sys

arguments = sys.argv[1:]
if arguments and arguments[0] == "retention-delete":
    state_index = arguments.index("--retention-state") + 1
    state_path = arguments[state_index]
    if (
        state_path == "$state_root/17-1-final-deploy"
        and not pathlib.Path("$state_root/17-1-final-deploy/concurrent-unknown.txt").exists()
    ):
        pathlib.Path("$state_root/17-1-final-deploy/concurrent-unknown.txt").write_text(
            "unknown-concurrent\n", encoding="utf-8"
        )
module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
raise SystemExit(module["main"](arguments))
EOF
FIXTURE_STATE_ROOT="$state_root" PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" "$state_root" "$production_runtime_root"

[ -d "$state_root/1-1-final-deploy" ]
[ -d "$state_root/10-1-final-deploy" ]
[ ! -e "$state_root/11-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy/provider-runtime" ]
[ -d "$state_root/12-1-final-deploy-shadow" ]
[ -d "$state_root/14-1-final-deploy" ]
[ -f "$state_root/14-1-final-deploy/unknown.txt" ]
[ -d "$state_root/17-1-final-deploy" ]
[ -f "$state_root/17-1-final-deploy/unknown-before-race.txt" ]
[ ! -e "$state_root/17-1-final-deploy/concurrent-unknown.txt" ]
[ ! -e "$tooling_root" ]

ln -s "$state_root/12-1-final-deploy" "$state_root/13-1-final-deploy"
set +e
symlink_output=$(FIXTURE_STATE_ROOT="$state_root" bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" \
  "$state_root" "$production_runtime_root" 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$symlink_output"
[ -L "$state_root/13-1-final-deploy" ]
rm -f -- "$state_root/13-1-final-deploy"

unresolved_state="$state_root/19-1-final-deploy"
fixture_install_dir 700 "$unresolved_state"
fixture_write "$unresolved_state/config.env.production" 600 <<'EOF'
pre-marker-snapshot
EOF
set +e
unresolved_output=$(FIXTURE_STATE_ROOT="$state_root" bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" \
  "$state_root" "$production_runtime_root" 2>&1)
unresolved_status=$?
set -e
[ "$unresolved_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$unresolved_output"
[ -d "$unresolved_state" ]
rm -r -- "$unresolved_state"

hard_state="$state_root/18-1-final-deploy"
fixture_install_dir 700 "$hard_state"
hard_witness="$fixture_root/operator-owned-terminal.json"
fixture_write "$hard_witness" 600 <<'EOF'
{"schemaVersion":1,"runKey":"18-1","outcome":"committed","providerEnabled":false}
EOF
rm -f -- "$hard_state/terminal.json"
ln "$hard_witness" "$hard_state/terminal.json"
fixture_touch -d '@1799999960.123456789' "$hard_state"
set +e
hard_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$hard_state" 2>&1)
hard_status=$?
set -e
[ "$hard_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$hard_output"
[ -d "$hard_state" ]
[ -f "$hard_witness" ]
[ "$(stat -c '%d:%i' "$hard_state/terminal.json")" = "$(stat -c '%d:%i' "$hard_witness")" ]
rm -r -- "$hard_state" "$hard_witness"
record_case symlink-hardlink-prefix-collision-denied

helper_before=$(find "$state_root" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' |
  sort)
set +e
malformed_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$state_root/../outside" 2>&1)
malformed_status=$?
set -e
[ "$malformed_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$malformed_output"
test "$helper_before" = "$(
  find "$state_root" -xdev -printf '%p|%y|%m|%u|%g|%l|%T@\n' | sort
)"

lock_state="$state_root/20-1-final-deploy"
fixture_install_dir 700 "$lock_state"
fixture_write "$lock_state/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"20-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$lock_state"
fixture_touch -d '@1799999950.123456789' "$lock_state"
lock_before=$(owned_digest "$lock_state")
python3 - "$state_root" scripts/test-vps-provider-credential.py \
  "$lock_state" <<'PY'
import subprocess
import sys

state_root, helper, state = sys.argv[1:]
holder = subprocess.Popen(
    [
        sys.executable,
        "-c",
        (
            "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); "
            "fcntl.flock(fd,fcntl.LOCK_EX); print('LOCKED',flush=True); "
            "sys.stdin.buffer.read(1); fcntl.flock(fd,fcntl.LOCK_UN)"
        ),
        state_root,
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
if holder.stdout is None or holder.stdout.readline() != b"LOCKED\n":
    holder.kill()
    raise SystemExit(1)
result = subprocess.run(
    [
        "timeout",
        "2s",
        sys.executable,
        helper,
        "retention-delete",
        "--state-root",
        state_root,
        "--retention-state",
        state,
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=5,
)
if result.returncode != 124:
    holder.stdin.write(b"x")
    holder.stdin.flush()
    holder.wait(timeout=3)
    raise SystemExit(1)
holder.stdin.write(b"x")
holder.stdin.flush()
holder.wait(timeout=3)
PY
test "$lock_before" = "$(owned_digest "$lock_state")"
record_case smtp-transaction-lock-contention-denied

malformed_state="$state_root/21-1-final-deploy"
fixture_install_dir 700 "$malformed_state"
fixture_write "$malformed_state/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"21-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$malformed_state"
fixture_touch -d '@1799999940.123456789' "$malformed_state"

hang_bin="$fixture_root/hang-bin"
fixture_install_dir 700 "$hang_bin"
real_timeout=$(command -v timeout)
fixture_write "$hang_bin/timeout" 700 <<EOF
#!/usr/bin/env bash
if [ "\${2:-}" = docker ]; then
  exit 124
fi
exec "$real_timeout" "\$@"
EOF
state="$state_root/16-1-final-deploy"
fixture_install_dir 700 "$state"
fixture_write "$state/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"16-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$state"
fixture_touch -d '@1799999980.123456789' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
fixture_install_dir 700 "$tooling_root/scripts"
fixture_copy scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
fixture_write "$tooling_root/scripts/test-vps-provider-credential.py" 700 <<EOF
#!/usr/bin/env python3
import runpy
import sys

module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
if sys.argv[1:2] == ["retention-delete"]:
    with open("$fixture_root/retention-events", "a", encoding="utf-8") as trace:
        trace.write("state-delete\\n")
raise SystemExit(module["main"](sys.argv[1:]))
EOF
operation_log=$fixture_root/retention-events
real_find=$(command -v find)
fixture_write "$fake_bin/find" 700 <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "\${FIXTURE_TOOLING_ROOT:-}" ] &&
  [[ " \$* " == *" -delete "* ]]; then
  echo tooling-delete >>"\$RETENTION_OPERATION_LOG"
fi
exec "$real_find" "\$@"
EOF
set +e
timeout_output=$(FIXTURE_STATE_ROOT="$state_root" \
  PATH="$hang_bin:$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" "$state_root" \
  "$production_runtime_root" 2>&1)
timeout_status=$?
set -e
[ "$timeout_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$timeout_output"
[ -d "$state" ]
[ -d "$tooling_root" ]
malformed_before=$(owned_digest "$malformed_state")
set +e
malformed_docker_output=$(RETENTION_MALFORMED_DOCKER=1 \
  FIXTURE_STATE_ROOT="$state_root" \
  FIXTURE_TOOLING_ROOT="$tooling_root" \
  RETENTION_OPERATION_LOG="$operation_log" \
  RETENTION_REAL_FIND="$real_find" \
  PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" "$state_root" \
  "$production_runtime_root" 2>&1)
malformed_docker_status=$?
set -e
[ "$malformed_docker_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$malformed_docker_output"
test "$malformed_before" = "$(owned_digest "$malformed_state")"
[ -d "$tooling_root" ]
record_case malformed-helper-inspection-denied
FIXTURE_STATE_ROOT="$state_root" \
FIXTURE_TOOLING_ROOT="$tooling_root" \
RETENTION_OPERATION_LOG="$operation_log" \
RETENTION_REAL_FIND="$real_find" \
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" "$state_root" "$production_runtime_root"
[ ! -e "$state" ]
[ ! -e "$tooling_root" ]
grep -Fxq state-delete "$operation_log"
[ "$(tail -n 1 "$operation_log")" = tooling-delete ]
record_case eligible-owned-terminal-states-removed
record_case active-protected-legacy-unknown-preserved
record_case all-service-mount-references-respected
record_case current-tooling-deleted-last

state="$state_root/15-1-final-deploy"
fixture_install_dir 700 "$state"
fixture_write "$state/terminal.json" 600 <<'EOF'
{"schemaVersion":1,"runKey":"15-1","outcome":"committed","providerEnabled":false}
EOF
write_owner_marker "$state"
fixture_touch -d '@1799999970.123456789' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
fixture_install_dir 700 "$tooling_root/scripts"
fixture_copy scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
fixture_write "$tooling_root/scripts/test-vps-provider-credential.py" 700 <<EOF
#!/usr/bin/env python3
import runpy
import sys

module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
raise SystemExit(module["main"](sys.argv[1:]))
EOF
FIXTURE_STATE_ROOT="$state_root" PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" "$state_root" "$production_runtime_root"
[ ! -e "$state_root/15-1-final-deploy" ]
[ ! -e "$tooling_root" ]
test "$legacy_before" = "$(legacy_digest)"
record_case repeat-run-is-idempotent
record_case timeout-hup-int-term-denied
record_case only-owned-roots-removed
record_case outside-sentinel-preserved
