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

fixture_root=$(mktemp -d /tmp/meet-retention-fixture.XXXXXX 2>/dev/null) ||
  prerequisite_missing
chmod 700 "$fixture_root" 2>/dev/null || prerequisite_missing
state_root=/var/lib/meet-test-vps-deploy
production_root=/var/lib/meet-retention-production
production_runtime_root=/var/lib/meet-production
fake_bin="$fixture_root/bin"
remote_script="$fixture_root/retention-remote.sh"
created_fixed_roots=()
created_fixed_root_identities=()
owned_root_recorder=record_created_root
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
  timeout 30s rm -r -- "$fixture_root" >/dev/null 2>&1 ||
    cleanup_status=1
  [ "$status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] || status=1
  exit "$status"
}
trap cleanup EXIT

if [ "${1:-}" = --check-fixed-roots ]; then
  for path in "$state_root" "$production_root" "$production_runtime_root"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "PREREQUISITE_MISSING: fixed fixture root already exists" >&2
      exit 77
    fi
  done
  exit 0
fi

for path in "$state_root" "$production_root" "$production_runtime_root"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "PREREQUISITE_MISSING: fixed fixture root already exists" >&2
    exit 77
  fi
done

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
  fixed_output=$(bash "$0" --check-fixed-roots 2>&1)
  fixed_status=$?
  set -e
  [ "$fixed_status" -eq 77 ]
  grep -Fq 'fixed fixture root already exists' <<<"$fixed_output"
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
case "${1:-}" in
  ps)
    printf 'fixture-backend\nfixture-provider\n'
    ;;
  inspect)
    case "${2:-}" in
      fixture-backend)
        printf '[{"Type":"volume","Name":"uploads","Destination":"/data/uploads"}]\n'
        ;;
      fixture-provider)
        printf '[{"Type":"bind","Source":"/var/lib/meet-test-vps-deploy/12-1-final-deploy/provider-runtime","Destination":"/run/provider"}]\n'
        ;;
      *)
        printf '{}\n'
        ;;
    esac
    ;;
  compose)
    case " $* " in
      *"/12-1-final-deploy/"*)
        printf '{"services":{"backend":{"volumes":[{"type":"bind","source":"/var/lib/meet-test-vps-deploy/12-1-final-deploy/protected-input","target":"/protected"}]}}}\n'
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
fixture_write "$remote_script" 700 <<<"$remote_content"

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
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"

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
symlink_output=$(bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" 2>&1)
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
unresolved_output=$(bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" 2>&1)
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
raise SystemExit(module["main"](sys.argv[1:]))
EOF
set +e
timeout_output=$(PATH="$hang_bin:$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" 2>&1)
timeout_status=$?
set -e
[ "$timeout_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$timeout_output"
[ -d "$state" ]
[ -d "$tooling_root" ]
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"
[ ! -e "$state" ]
[ ! -e "$tooling_root" ]

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
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"
[ ! -e "$state_root/15-1-final-deploy" ]
[ ! -e "$tooling_root" ]
test "$legacy_before" = "$(legacy_digest)"
echo "retention fixture passed: all-service mounts, timeout failure, self-tooling ordering, repeated-run cleanup, protected reference, unknown, symlink and prefix-collision cases"
