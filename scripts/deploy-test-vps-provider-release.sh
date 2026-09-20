#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

is_supported_test_vps_version() {
  local version=${1:-}
  local major minor patch
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    return 1
  IFS=. read -r major minor patch <<<"$version"
  (( major > 1 ||
    (major == 1 && (minor > 2 || (minor == 2 && patch >= 0))) ))
}

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" >&2
  exit 2
}

fail() {
  echo "test VPS deployment failed: $1" >&2
  exit 1
}

verify_production_env_settings() {
  timeout 30s python3 - "$1" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
info = os.lstat(path)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
    raise SystemExit(1)
data = open(path, "rb").read(1024 * 1024 + 1)
if len(data) > 1024 * 1024:
    raise SystemExit(1)
try:
    text = data.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)

push_keys = {
    "APP_PUSH_PROVIDER_ENABLED",
    "APP_PUSH_DISCOVERY_ENABLED",
    "APP_PUSH_DISPATCH_ENABLED",
    "APP_PUSH_DIAGNOSTIC_ENABLED",
    "APP_PUSH_MAINTENANCE_ENABLED",
    "APP_PUSH_PROJECT_ID",
    "APP_PUSH_CREDENTIALS_FILE",
}
alternate = {
    "SPRING_APPLICATION_JSON",
    "SPRING_CONFIG_LOCATION",
    "SPRING_CONFIG_ADDITIONAL_LOCATION",
    "SPRING_CONFIG_IMPORT",
    "SPRING_CONFIG_NAME",
    "SPRING_CONFIG_DATA_LOCATION",
}
seen = set()
for raw in text.splitlines():
    line = raw.rstrip("\r")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
    if match is None:
        raise SystemExit(1)
    key, value = match.groups()
    normalized = key.upper().replace("-", "_").replace(".", "_")
    if normalized in push_keys:
        if key != normalized or key in seen:
            raise SystemExit(1)
        seen.add(key)
    if normalized in alternate:
        raise SystemExit(1)
    if key in {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"}:
        lowered = value.lower()
        if any(
            token in lowered
            for token in (
                "app.push",
                "spring.application.json",
                "spring.config.location",
                "spring.config.additional-location",
                "spring.config.import",
                "spring.config.name",
                "spring.config.data.location",
            )
        ):
            raise SystemExit(1)
PY
}

verify_public_contract() {
  local public_url=${1:-}
  [ -n "$public_url" ] || return 0
  local meetings_probe actuator_status redirect_headers redirect_status
  meetings_probe=$(timeout 30s curl --silent --connect-timeout 5 \
    --max-time 15 --write-out $'\n%{http_code}' \
    "$public_url/meetings" 2>/dev/null |
    timeout 5s python3 -c '
import json
import sys

data = sys.stdin.buffer.read(8 * 1024 * 1024 + 64)
body, separator, status = data.rpartition(b"\n")
if not separator or len(body) > 8 * 1024 * 1024 or status != b"200":
    raise SystemExit(1)
try:
    value = json.loads(body.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
print("meetings_status=200 meetings_array=true")
') || fail "public meetings probe failed"
  [ "$meetings_probe" = "meetings_status=200 meetings_array=true" ] ||
    fail "public meetings probe failed"
  actuator_status=$(curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --output /dev/null --write-out '%{http_code}' \
    "$public_url/actuator" 2>/dev/null) || fail "public actuator probe failed"
  [ "$actuator_status" = 404 ] || fail "public actuator probe failed"
  redirect_headers=$(curl --silent --connect-timeout 5 --max-time 15 \
    --dump-header - --output /dev/null --write-out '%{http_code}' \
    "${public_url/https:\/\//http://}/meetings" 2>/dev/null) ||
    fail "public redirect probe failed"
  redirect_status=${redirect_headers: -3}
  case "$redirect_status" in 301|302|307|308) ;; *)
    fail "public redirect probe failed"
    ;;
  esac
  grep -Eiq '^location:[[:space:]]+https://' <<<"$redirect_headers" ||
    fail "public redirect probe failed"
  local missing_admin wrong_admin
  missing_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}' 2>/dev/null) ||
    fail "admin guard probe failed"
  wrong_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' \
    --data '{}' 2>/dev/null) || fail "admin guard probe failed"
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
    fail "admin guard probe failed"
}

runtime_release_field_bounded() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_release_field "$2" "$3"
  ' _ "$runtime_helper" "$root" "$1"
}

configuration_file_identity() {
  timeout 30s python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
try:
    if os.path.islink(path):
        raise OSError(40, "symlink")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError:
    raise SystemExit(1)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    print(
        f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
        f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
        f"{digest.hexdigest()}"
    )
finally:
    os.close(fd)
PY
}

snapshot_configuration() {
  local source snapshot identity
  for source in "$root/.env.production" "$base_compose"; do
    case "$source" in
      "$root/.env.production") snapshot="$state/config.env.production" ;;
      "$base_compose") snapshot="$state/config.base-compose.yml" ;;
      *) fail "PROVIDER_STATE_INVALID" ;;
    esac
    identity=$(configuration_file_identity "$source") ||
      fail "PROVIDER_STATE_INVALID"
    timeout 30s install -m 600 "$source" "$snapshot" ||
      fail "PROVIDER_STATE_INVALID"
    cmp -s "$source" "$snapshot" ||
      fail "PROVIDER_STATE_INVALID"
    [ "$(configuration_file_identity "$source")" = "$identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    printf '%s\n' "$identity" >"$snapshot.identity"
    chmod 600 "$snapshot.identity"
  done
}

validate_configuration_boundary() {
  local expected_env=$1
  local source expected expected_identity expected_value
  [ -f "$expected_env" ] && [ ! -L "$expected_env" ] ||
    fail "PROVIDER_STATE_INVALID"
  for source in "$root/.env.production" "$base_compose"; do
    case "$source" in
      "$root/.env.production")
        expected=$expected_env
        case "$expected_env" in
          "$state/config.env.production") expected_identity="$state/config.env.production.identity" ;;
          "$state/config.env.target") expected_identity="$state/config.env.target.identity" ;;
          "$state/config.env.previous") expected_identity="$state/config.env.previous.identity" ;;
          *) fail "PROVIDER_STATE_INVALID" ;;
        esac
        ;;
      "$base_compose")
        expected="$state/config.base-compose.yml"
        expected_identity="$state/config.base-compose.yml.identity"
        ;;
      *) fail "PROVIDER_STATE_INVALID" ;;
    esac
    cmp -s "$source" "$expected" ||
      fail "PROVIDER_STATE_INVALID"
    [ -s "$expected_identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    expected_value=$(<"$expected_identity")
    [ "$(configuration_file_identity "$source")" = "$expected_value" ] ||
      fail "PROVIDER_STATE_INVALID"
  done
}

make_environment_candidate() {
  timeout 30s python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import os
import pathlib
import re
import sys

source, destination, image, revision, version = sys.argv[1:]
data = pathlib.Path(source).read_bytes().decode("utf-8")
replacements = {
    "BACKEND_IMAGE": image,
    "BACKEND_REVISION": revision,
    "BACKEND_VERSION": version,
}
seen = set()
lines = []
for line in data.splitlines(keepends=True):
    match = re.match(r"^(BACKEND_IMAGE|BACKEND_REVISION|BACKEND_VERSION)=", line)
    if match:
        key = match.group(1)
        if key in seen:
            raise SystemExit(1)
        seen.add(key)
        line_without_ending = line.rstrip("\r\n")
        line_ending = line[len(line_without_ending):]
        lines.append(f"{key}={replacements[key]}{line_ending}")
    else:
        lines.append(line)
if seen != set(replacements):
    raise SystemExit(1)
path = pathlib.Path(destination)
fd = os.open(
    path,
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_BINARY", 0),
    0o600,
)
try:
    os.write(fd, "".join(lines).encode("utf-8"))
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

active_file_identity() {
  local file=$1
  configuration_file_identity "$file"
}

snapshot_active_file() {
  local file=$1
  local name=$2
  local identity
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || fail "PROVIDER_STATE_INVALID"
    identity=$(active_file_identity "$file") || fail "PROVIDER_STATE_INVALID"
    printf '%s\n' "$identity" >"$state/previous-active-$name.identity"
    timeout 30s install -m 600 "$file" "$state/previous-active-$name.yml" ||
      fail "PROVIDER_STATE_INVALID"
    cmp -s "$file" "$state/previous-active-$name.yml" ||
      fail "PROVIDER_STATE_INVALID"
    [ "$(active_file_identity "$file")" = "$identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    : >"$state/had-active-$name"
  fi
}

validate_active_files_before_writers() {
  local name file expected actual
  for name in compose runtime; do
    if [ -e "$state/had-active-$name" ]; then
      case "$name" in
        compose) file=$active_compose ;;
        runtime) file=$active_runtime ;;
        *) fail "PROVIDER_STATE_INVALID" ;;
      esac
      expected=$(<"$state/previous-active-$name.identity")
      actual=$(active_file_identity "$file") ||
        fail "PROVIDER_STATE_INVALID"
      [ "$actual" = "$expected" ] || fail "PROVIDER_STATE_INVALID"
      cmp -s "$file" "$state/previous-active-$name.yml" ||
        fail "PROVIDER_STATE_INVALID"
    else
      case "$name" in
        compose) file=$active_compose ;;
        runtime) file=$active_runtime ;;
        *) fail "PROVIDER_STATE_INVALID" ;;
      esac
      [ ! -e "$file" ] && [ ! -L "$file" ] ||
        fail "PROVIDER_STATE_INVALID"
    fi
  done
}

record_candidate_active_file() {
  local file=$1
  local name=$2
  local identity
  [ -f "$file" ] && [ ! -L "$file" ] ||
    fail "RECOVERY_REQUIRED"
  timeout 30s install -m 600 "$file" \
    "$state/candidate-active-$name.yml" ||
    fail "RECOVERY_REQUIRED"
  identity=$(active_file_identity "$file") || fail "RECOVERY_REQUIRED"
  printf '%s\n' "$identity" >"$state/candidate-active-$name.identity"
}

restore_active_file() {
  local file=$1
  local name=$2
  if ! timeout 30s python3 - "$file" "$state" "$name" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

file_path, state, name = sys.argv[1:]
parent, basename = os.path.split(file_path)
if not parent or not basename or "/" in basename:
    raise SystemExit(1)

def read_private(path):
    if os.path.islink(path):
        raise SystemExit(1)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        return os.read(fd, 1024 * 1024 * 16)
    finally:
        os.close(fd)

def identity(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
    digest = hashlib.sha256()
    offset = 0
    while offset < info.st_size:
        chunk = os.pread(fd, min(1024 * 1024, info.st_size - offset), offset)
        if not chunk:
            raise SystemExit(1)
        digest.update(chunk)
        offset += len(chunk)
    return (
        f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
        f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
        f"{digest.hexdigest()}"
    )

def open_current(directory_fd):
    info = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
    if stat.S_ISLNK(info.st_mode):
        raise OSError(40, "symlink")
    return os.open(
        basename,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )

parent_fd = os.open(
    parent,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    fcntl.flock(parent_fd, fcntl.LOCK_EX)
    previous_exists = os.path.exists(os.path.join(state, f"had-active-{name}"))
    previous_bytes = read_private(
        os.path.join(state, f"previous-active-{name}.yml")
    ) if previous_exists else b""
    candidate_identity_path = os.path.join(
        state, f"candidate-active-{name}.identity"
    )
    candidate_bytes_path = os.path.join(state, f"candidate-active-{name}.yml")
    candidate_identity = read_private(candidate_identity_path).decode().strip() \
        if os.path.exists(candidate_identity_path) else ""
    candidate_bytes = read_private(candidate_bytes_path) \
        if os.path.exists(candidate_bytes_path) else b""

    try:
        current_fd = open_current(parent_fd)
    except FileNotFoundError:
        current_fd = None
    if previous_exists:
        if current_fd is None:
            raise SystemExit(1)
        try:
            current_identity = identity(current_fd)
            os.lseek(current_fd, 0, os.SEEK_SET)
            current_bytes = os.read(current_fd, 16 * 1024 * 1024)
        finally:
            os.close(current_fd)
        if current_identity == read_private(
            os.path.join(state, f"previous-active-{name}.identity")
        ).decode().strip():
            if current_bytes != previous_bytes:
                raise SystemExit(1)
            raise SystemExit(0)
        if not candidate_identity or current_identity != candidate_identity:
            raise SystemExit(1)
        if current_bytes != candidate_bytes:
            raise SystemExit(1)
        replacement = previous_bytes
    else:
        if current_fd is None:
            raise SystemExit(0)
        try:
            current_identity = identity(current_fd)
            os.lseek(current_fd, 0, os.SEEK_SET)
            current_bytes = os.read(current_fd, 16 * 1024 * 1024)
        finally:
            os.close(current_fd)
        if not candidate_identity or current_identity != candidate_identity:
            raise SystemExit(1)
        if current_bytes != candidate_bytes:
            raise SystemExit(1)
        os.unlink(basename, dir_fd=parent_fd)
        os.fsync(parent_fd)
        raise SystemExit(0)

    temporary = f".{basename}.rollback.{os.getpid()}"
    temp_fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent_fd,
    )
    try:
        view = memoryview(replacement)
        while view:
            written = os.write(temp_fd, view)
            view = view[written:]
        os.fsync(temp_fd)
        os.fchmod(temp_fd, 0o600)
    finally:
        os.close(temp_fd)
    os.replace(
        temporary,
        basename,
        src_dir_fd=parent_fd,
        dst_dir_fd=parent_fd,
    )
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
  then
    echo "RECOVERY_REQUIRED" >&2
    return 1
  fi
}

provider_release_main() {
root=
base_compose=
image=
revision=
version=
run_key=
mode=
closed_beta_safety=false
public_url=
state_mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2 ;;
    --base-compose) [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage; base_compose=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --revision) [ "$#" -ge 2 ] && [ -z "$revision" ] || usage; revision=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] && [ -z "$version" ] || usage; version=$2; shift 2 ;;
    --run-key) [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage; run_key=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] && [ -z "$mode" ] || usage; mode=$2; shift 2 ;;
    --closed-beta-safety)
      [ "$closed_beta_safety" = false ] || usage
      closed_beta_safety=true
      shift
      ;;
    --state-mode)
      [ "$#" -ge 2 ] && [ -z "$state_mode" ] || usage
      state_mode=$2
      shift 2
      ;;
    --public-url)
      [ "$#" -ge 2 ] && [ -z "$public_url" ] || usage
      public_url=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$base_compose" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$base_compose" != *..* ]] || usage
[[ "$image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
  usage
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  usage
is_supported_test_vps_version "$version" ||
  fail "target version must be at least v1.2.0"
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in deploy|rollback-drill) ;; *) usage ;; esac
if [ -n "$public_url" ]; then
  [[ "$public_url" =~ ^https://[^/]+$ ]] || usage
fi
if [ "$closed_beta_safety" = true ]; then
  case "$state_mode" in empty-closed|closed-beta-demo) ;; *) usage ;; esac
elif [ -n "$state_mode" ]; then
  usage
fi

for command_name in docker curl jq flock python3 timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done
if timeout 1s sh -c 'sleep 2' >/dev/null 2>&1; then
  fail "timeout capability is unavailable"
else
  timeout_status=$?
  [ "$timeout_status" -eq 124 ] ||
    fail "timeout capability is unavailable"
fi
[ "$(id -u)" -eq 0 ] || fail "the test VPS deploy must run as root"
[ -d "$root" ] || fail "deployment root is unavailable"
[ -s "$root/.env.production" ] || fail "existing production environment is unavailable"
[ -s "$root/docker-compose.production.yml" ] ||
  fail "existing production Compose file is unavailable"
[ -s "$base_compose" ] || fail "reviewed target Compose file is unavailable"
verify_production_env_settings "$root/.env.production" ||
  fail "PROVIDER_STATE_INVALID"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_script=$script_dir/production-compose.sh
update_script=$script_dir/update-production-release.sh
runtime_helper=$script_dir/test-vps-runtime-invariants.sh
safety_hook=$script_dir/verify-test-vps-closed-beta-state.sh
provider_helper=$script_dir/test-vps-provider-credential.py
[ -x "$compose_script" ] || fail "reviewed Compose wrapper is unavailable"
[ -x "$update_script" ] || fail "reviewed release updater is unavailable"
[ -r "$runtime_helper" ] || fail "runtime invariant helper is unavailable"
[ -f "$provider_helper" ] && [ ! -L "$provider_helper" ] && [ -r "$provider_helper" ] ||
  fail "provider credential helper is unavailable"
timeout 30s python3 "$provider_helper" check >/dev/null ||
  fail "PREREQUISITE_MISSING"
# shellcheck source=/dev/null
source "$runtime_helper"

docker_image_inspect() {
  timeout 30s docker image inspect "$@" 2>/dev/null
}

docker_container_inspect() {
  timeout 30s docker inspect "$@" 2>/dev/null
}

runtime_image_id_bounded() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_image_id "$2" "$3"
  ' _ "$runtime_helper" "$root" "$compose_script"
}

runtime_environment_bounded() {
  timeout 60s bash -c '
    set -euo pipefail
    source "$1"
    verify_environment_matches_container "$2" "$3"
  ' _ "$runtime_helper" "$root" "$compose_script"
}

runtime_invariants_bounded() {
  timeout 60s bash -c '
    set -euo pipefail
    source "$1"
    verify_runtime_invariants "$2" "$3" "$4" "$5" "$6" "$7"
  ' _ "$runtime_helper" "$root" "$compose_script" "$1" "$2" "$3" "$4" "$5"
}

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
smtp_pointer=$state_root/.smtp-transaction.current
provider_pointer=$state_root/.provider-transaction.current
state_suffix=final-deploy
[ "$mode" = rollback-drill ] && state_suffix=rollback-drill
state=$state_root/$run_key-$state_suffix
install -d -m 700 "$state_root"
exec 9>"$state_root/.deploy.lock"
flock -n 9 || fail "another test VPS deployment is active"
if [ "$closed_beta_safety" = true ]; then
  [ -f "$safety_hook" ] && [ ! -L "$safety_hook" ] && [ -x "$safety_hook" ] ||
    fail "closed-beta safety hook is unavailable"
fi

# This is intentionally an existence/type-only interlock.  SMTP tooling owns
# parsing, recovery, terminal publication, and cleanup of every object class.
if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]; then
  fail "SMTP transaction is active; reconcile it with the SMTP tooling first"
fi
if [ -e "$provider_pointer" ] || [ -L "$provider_pointer" ]; then
  fail "RECOVERY_REQUIRED"
fi
timeout 30s python3 "$provider_helper" retention-check \
  --state-root "$state_root" >/dev/null ||
  fail "RECOVERY_REQUIRED"

[ ! -e "$state" ] || fail "run state already exists"
install -d -m 700 "$state"

compose() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" "$@" 2>/dev/null
}

compose_up() {
  timeout 240s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" "$@" 2>/dev/null
}

previous_image=$(runtime_release_field_bounded BACKEND_IMAGE) ||
  fail "PROVIDER_STATE_INVALID"
previous_version=$(runtime_release_field_bounded BACKEND_VERSION) ||
  fail "PROVIDER_STATE_INVALID"
previous_revision=$(runtime_release_field_bounded BACKEND_REVISION) ||
  fail "PROVIDER_STATE_INVALID"
[[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "running revision is malformed"
[[ "$previous_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "running version is malformed"
is_supported_test_vps_version "$previous_version" ||
  fail "predecessor version must be at least v1.2.0"
previous_id=$(runtime_image_id_bounded) ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$previous_image" --format '{{.Id}}')" = "$previous_id" ] ||
  fail "PROVIDER_STATE_INVALID"
previous_container=$(compose ps -q backend)
[ -n "$previous_container" ] || fail "predecessor backend is unavailable"
previous_runtime_hash=$(docker_container_inspect "$previous_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "PROVIDER_STATE_INVALID"
[[ "$previous_runtime_hash" =~ ^[0-9a-f]{64}$ ]]
runtime_invariants_bounded "$previous_id" "$previous_revision" \
  "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 ||
  fail "PROVIDER_STATE_INVALID"
runtime_environment_bounded >/dev/null 2>&1 ||
  fail "running container does not match the current production environment"
previous_inspect=$(docker_container_inspect "$previous_container" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
provider_observed=$(printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" observe) ||
  fail "PROVIDER_STATE_INVALID"
jq -e '
  type == "object" and .schemaVersion == 1 and
  (.providerEnabled | type == "boolean") and
  (.credentialMountPresent | type == "boolean") and
  (.credentialMountReadOnly | type == "boolean") and
  (.outcome == "observed")
' <<<"$provider_observed" >/dev/null || fail "PROVIDER_STATE_INVALID"
provider_enabled=$(jq -r '.providerEnabled' <<<"$provider_observed")

# Register the transaction before creating any private snapshot or identity
# file.  An interrupted pre-marker snapshot is otherwise indistinguishable
# from an abandoned ordinary run directory to retention.
write_provider_marker preparing none

snapshot_configuration
validate_configuration_boundary "$state/config.env.production"
printf '%s\n' "$previous_image" >"$state/previous-image"
printf '%s\n' "$previous_id" >"$state/previous-image-id"
printf '%s\n' "$previous_revision" >"$state/previous-revision"
printf '%s\n' "$previous_version" >"$state/previous-version"
printf '%s\n' "$previous_runtime_hash" >"$state/previous-runtime-config-hash"
if [ -e "$active_compose" ]; then
  [ -s "$active_compose" ] || fail "active Compose file is empty"
fi
if [ -e "$active_runtime" ]; then
  [ -s "$active_runtime" ] || fail "active runtime override is empty"
fi
snapshot_active_file "$active_compose" compose
snapshot_active_file "$active_runtime" runtime

run_safety_hook() {
  local phase=$1
  local expected_image=$2
  local expected_id=$3
  local expected_revision=$4
  local expected_version=$5
  local expected_runtime_hash=$6
  local output=$state/$phase.json
  [ "$closed_beta_safety" = true ] || return 0
  [ ! -e "$output" ] && [ ! -L "$output" ] ||
    fail "closed-beta $phase evidence already exists"
  safety_args=(
    --phase "$phase"
    --root "$root"
    --compose-script "$compose_script"
    --state-dir "$state"
    --expected-image "$expected_image"
    --expected-image-id "$expected_id"
    --expected-revision "$expected_revision"
    --expected-version "$expected_version"
    --expected-runtime-hash "$expected_runtime_hash"
    --state-mode "$state_mode"
  )
  if [ -n "$public_url" ]; then
    safety_args+=(--public-url "$public_url")
  fi
  timeout 60s "$safety_hook" "${safety_args[@]}" \
    --output "$output" >/dev/null 2>&1 ||
    fail "RECOVERY_REQUIRED"
  [ -f "$output" ] && [ ! -L "$output" ] && [ -s "$output" ] ||
    fail "closed-beta $phase evidence is unavailable"
  chmod 600 "$output"
  if [ "$phase" = final ] && [ -n "$public_url" ]; then
    timeout 60s "$script_dir/verify-test-vps-assets.sh" \
      --public-url "$public_url" \
      --output "$state/frozen-assets.json" >/dev/null 2>&1 ||
      fail "RECOVERY_REQUIRED"
    curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=https' --tlsv1.2 \
      "$public_url/meetings" | jq -e 'type == "array"' >/dev/null
    [ "$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=https' --tlsv1.2 \
      -o /dev/null -w '%{http_code}' "$public_url/actuator")" = 404 ] ||
      fail "Actuator is not private"
    headers=$(mktemp)
    trap 'rm -f -- "$headers"' RETURN
    curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=http' \
      -D "$headers" -o /dev/null "${public_url/https:\/\//http://}/meetings"
    grep -Eiq '^location: https://' "$headers" ||
      fail "HTTP does not redirect to HTTPS"
    rm -f -- "$headers"
    missing_admin=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'Content-Type: application/json' --data '{}')
    wrong_admin=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
    [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
      fail "admin guard did not reject unauthenticated requests"
  fi
}

write_provider_marker() {
  local phase=$1
  local disposition=$2
  local temporary="$state_root/.provider-transaction.$run_key.tmp"
  case "$phase" in preparing|prepared|applying|verifying|rolling-back|finalizing) ;; *)
    fail "RECOVERY_REQUIRED"
    ;;
  esac
  case "$disposition" in none|created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
  if [ "$phase" = preparing ]; then
    [ ! -e "$provider_pointer" ] && [ ! -L "$provider_pointer" ] ||
      fail "RECOVERY_REQUIRED"
  fi
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || fail "RECOVERY_REQUIRED"
  umask 077
  printf '{"schemaVersion":1,"runKey":"%s","phase":"%s","providerEnabled":%s,"durableDisposition":"%s"}\n' \
    "$run_key" "$phase" "$provider_enabled" "$disposition" >"$temporary"
  chmod 600 "$temporary"
  timeout 30s python3 - "$temporary" "$state_root" <<'PY'
import os
import sys

for path, directory in ((sys.argv[1], False), (sys.argv[2], True)):
    flags = os.O_RDONLY | (os.O_DIRECTORY if directory else 0)
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  timeout 30s mv -f -- "$temporary" "$provider_pointer"
  timeout 30s python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

write_terminal_record() {
  local outcome=$1
  local terminal="$state/terminal.json"
  [ "$outcome" = committed ] || [ "$outcome" = rolled-back ] ||
    fail "RECOVERY_REQUIRED"
  umask 077
  timeout 30s jq -cn --arg run_key "$run_key" --arg outcome "$outcome" \
    --argjson enabled "$provider_enabled" \
    '{schemaVersion:1,runKey:$run_key,outcome:$outcome,providerEnabled:$enabled}' \
    >"$terminal"
  chmod 600 "$terminal"
  timeout 30s python3 - "$terminal" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

provider_finish() {
  local outcome=$1
  local inspection=$2
  write_provider_marker finalizing \
    "${durable_disposition:-none}"
  printf '%s' "$inspection" |
    timeout 30s python3 "$provider_helper" finish \
      --run-key "$run_key" --state-root "$state_root" \
      --outcome "$outcome" >/dev/null ||
    fail "RECOVERY_REQUIRED"
  write_terminal_record "$outcome"
  timeout 30s rm -f -- "$provider_pointer" || fail "RECOVERY_REQUIRED"
  timeout 30s python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  timeout 30s jq -cn --argjson enabled "$provider_enabled" --arg outcome "$outcome" \
    '{schemaVersion:1,providerEnabled:$enabled,credentialMountPresent:$enabled,
      credentialMountReadOnly:$enabled,outcome:$outcome}'
}

mutation_started=false
credential_prepared=false
rollback_complete=false
updater_started=false
updater_completed=false
cleanup_inspect=
recovery_started_at=
recovery_deadline_check() {
  [ -n "$recovery_started_at" ] || return 0
  [ "$((SECONDS - recovery_started_at))" -lt 600 ] ||
    fail "RECOVERY_REQUIRED"
}
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$rollback_complete" = false ]; then
    if [ "$mutation_started" = true ]; then
      rollback || status=1
    elif [ "$credential_prepared" = true ]; then
      if verify_predecessor_for_cleanup; then
        provider_finish rolled-back "$cleanup_inspect" || status=1
      else
        status=1
      fi
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 143' TERM INT HUP

target_id=$(docker_image_inspect "$image" --format '{{.Id}}') ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$revision" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$version" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
  "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" --format '{{.Config.User}}')" = 10001:10001 ] ||
  fail "PROVIDER_STATE_INVALID"
if [ "$mode" = rollback-drill ] && [ "$target_id" = "$previous_id" ]; then
  fail "rollback drill requires a target image distinct from the predecessor"
fi
target_image_inspect=$(docker_image_inspect "$image" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
printf '%s' "$target_image_inspect" |
  timeout 30s python3 "$provider_helper" check-image >/dev/null ||
  fail "PROVIDER_STATE_INVALID"
run_safety_hook predecessor "$previous_image" "$previous_id" \
  "$previous_revision" "$previous_version" "$previous_runtime_hash"

if [ "$provider_enabled" = true ]; then
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
    volumes:
      - type: bind
        source: /var/lib/meet-production/credentials/firebase-service-account.json
        target: /run/secrets/meet-firebase-service-account.json
        read_only: true
        bind:
          create_host_path: false
YAML
else
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
YAML
fi
chmod 600 "$state/target-runtime.override.yml"

target_config=$(
  env -i PATH="$PATH" HOME=/root COMPOSE_PROJECT_NAME=meet-production \
    BACKEND_IMAGE="$image" BACKEND_VERSION="$version" BACKEND_REVISION="$revision" \
    timeout 30s docker compose --project-directory "$root" \
    --env-file "$state/config.env.production" \
    -f "$state/config.base-compose.yml" -f "$state/target-runtime.override.yml" \
    config --format json 2>/dev/null
) || fail "PROVIDER_STATE_INVALID"
printf '%s\n%s\n%s\n' "$previous_inspect" "$target_image_inspect" "$target_config" |
  jq -s -e '
    def envmap:
      if type == "array" then
        reduce .[] as $entry ({};
          if ($entry | type) != "string" or ($entry | contains("=") | not)
          then error("invalid environment")
          else ($entry | index("=")) as $i |
            ($entry[0:$i]) as $key |
            if has($key) then error("duplicate environment") else
              . + {($key): $entry[($i + 1):]}
            end
          end)
      elif type == "object" then
        reduce to_entries[] as $entry ({};
          if ($entry.value | type) != "string"
          then error("unresolved environment")
          else . + {($entry.key):$entry.value}
          end)
      else {}
      end;
    def effective($imageEnv; $targetEnv):
      ($imageEnv | envmap) + ($targetEnv | envmap);
    def tuple($env):
      {
        APP_PUSH_PROVIDER_ENABLED: ($env.APP_PUSH_PROVIDER_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISCOVERY_ENABLED: ($env.APP_PUSH_DISCOVERY_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISPATCH_ENABLED: ($env.APP_PUSH_DISPATCH_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DIAGNOSTIC_ENABLED: ($env.APP_PUSH_DIAGNOSTIC_ENABLED // "false" | ascii_downcase),
        APP_PUSH_MAINTENANCE_ENABLED: ($env.APP_PUSH_MAINTENANCE_ENABLED // "false" | ascii_downcase),
        APP_PUSH_PROJECT_ID: ($env.APP_PUSH_PROJECT_ID // "meeting-1d258"),
        APP_PUSH_CREDENTIALS_FILE: ($env.APP_PUSH_CREDENTIALS_FILE // "")
      };
    (.[0][0].Config.Env | envmap) as $previous |
    (.[1][0].Config.Env | envmap) as $image |
    (.[2].services.backend.environment // {}) as $target |
    (effective($image; $target) | tuple(.)) == (tuple($previous)) and
    (tuple($previous).APP_PUSH_PROVIDER_ENABLED == "true" or
      tuple($previous).APP_PUSH_PROVIDER_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISPATCH_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISPATCH_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "true" or
      tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "false") and
    (tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "true" or
      tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "false")
  ' >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"

make_environment_candidate "$state/config.env.production" \
  "$state/config.env.target" "$image" "$revision" "$version" ||
  fail "PROVIDER_STATE_INVALID"
make_environment_candidate "$state/config.env.production" \
  "$state/config.env.previous" "$previous_image" "$previous_revision" \
  "$previous_version" || fail "PROVIDER_STATE_INVALID"

printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" prepare \
    --run-key "$run_key" --state-root "$state_root" >/dev/null ||
  fail "CREDENTIAL_INVALID"
durable_disposition=$(timeout 5s jq -er \
  --arg run_key "$run_key" --argjson enabled "$provider_enabled" '
    select(
      type == "object" and
      .schemaVersion == 1 and
      .runKey == $run_key and
      .phase == "preparing" and
      .providerEnabled == $enabled
    ) |
    .durableDisposition |
    select(. == "none" or . == "created" or . == "reused")
  ' \
  "$provider_pointer") || fail "RECOVERY_REQUIRED"
if [ "$provider_enabled" = true ]; then
  case "$durable_disposition" in created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
else
  [ "$durable_disposition" = none ] || fail "RECOVERY_REQUIRED"
fi
write_provider_marker prepared "$durable_disposition"
credential_prepared=true

restore_previous_active_files() {
  restore_active_file "$active_compose" compose || fail "RECOVERY_REQUIRED"
  restore_active_file "$active_runtime" runtime || fail "RECOVERY_REQUIRED"
}

rollback() {
  recovery_started_at=$SECONDS
  recovery_deadline_check
  if [ "$updater_completed" = true ]; then
    validate_configuration_boundary "$state/config.env.target"
  elif [ "$updater_started" = false ]; then
    validate_configuration_boundary "$state/config.env.production"
  fi
  write_provider_marker rolling-back "${durable_disposition:-none}"
  restore_previous_active_files
  if [ "$updater_completed" = true ]; then
    validate_configuration_boundary "$state/config.env.target"
  fi
  updater_started=true
  PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
    timeout 60s "$update_script" "$previous_image" "$previous_revision" "$previous_version" \
    >/dev/null 2>&1 || fail "RECOVERY_REQUIRED"
  cmp -s "$root/.env.production" "$state/config.env.previous" ||
    fail "RECOVERY_REQUIRED"
  printf '%s\n' "$(configuration_file_identity "$root/.env.production")" \
    >"$state/config.env.previous.identity"
  chmod 600 "$state/config.env.previous.identity"
  validate_configuration_boundary "$state/config.env.previous"
  compose_up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout 180 backend >/dev/null
  recovery_deadline_check
  restored_container=$(compose ps -q backend)
  restored_inspect=$(docker_container_inspect "$restored_container" 2>/dev/null) ||
    fail "RECOVERY_REQUIRED"
  restored_hash=$(docker_container_inspect "$restored_container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  [ "$restored_hash" = "$previous_runtime_hash" ] ||
    fail "rollback did not restore the exact predecessor Compose runtime"
  runtime_invariants_bounded "$previous_id" "$previous_revision" \
    "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 ||
    fail "RECOVERY_REQUIRED"
  printf '[%s,%s]' "$previous_inspect" "$restored_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase rollback >/dev/null ||
    fail "RECOVERY_REQUIRED"
  verify_public_contract "$public_url"
  recovery_deadline_check
  run_safety_hook rollback "$previous_image" "$previous_id" \
    "$previous_revision" "$previous_version" "$previous_runtime_hash"
  provider_finish rolled-back "$restored_inspect"
  rollback_complete=true
  echo "rollback=completed previous_image_id=$previous_id"
}

verify_predecessor_before_writers() {
  local current_container current_inspect
  current_container=$(compose ps -q backend) ||
    fail "PROVIDER_STATE_INVALID"
  [ -n "$current_container" ] || fail "PROVIDER_STATE_INVALID"
  current_inspect=$(docker_container_inspect "$current_container" 2>/dev/null) ||
    fail "PROVIDER_STATE_INVALID"
  printf '[%s,%s]' "$previous_inspect" "$current_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase predecessor >/dev/null ||
    fail "PROVIDER_STATE_INVALID"
}

verify_predecessor_for_cleanup() {
  local current_container current_inspect
  current_container=$(compose ps -q backend 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  [ -n "$current_container" ] || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  current_inspect=$(docker_container_inspect "$current_container" 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  cleanup_inspect=$current_inspect
  runtime_invariants_bounded "$previous_id" "$previous_revision" \
    "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 || {
      echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
      return 1
    }
  runtime_environment_bounded >/dev/null 2>&1 || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  if ! (verify_public_contract "$public_url" >/dev/null 2>&1); then
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  fi
  local final_container final_inspect
  final_container=$(compose ps -q backend 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  [ "$final_container" = "$current_container" ] || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  final_inspect=$(docker_container_inspect "$final_container" 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  cleanup_inspect=$final_inspect
  printf '[%s,%s]' "$previous_inspect" "$final_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase predecessor \
      >/dev/null || {
        echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
        return 1
      }
}

validate_active_files_before_writers
verify_predecessor_before_writers
validate_configuration_boundary "$state/config.env.production"
write_provider_marker applying "$durable_disposition"
mutation_started=true
validate_configuration_boundary "$state/config.env.production"
timeout 30s install -m 600 "$state/config.base-compose.yml" "$active_compose" ||
  fail "PROVIDER_STATE_INVALID"
record_candidate_active_file "$active_compose" compose
validate_configuration_boundary "$state/config.env.production"
timeout 30s install -m 600 "$state/target-runtime.override.yml" "$active_runtime" ||
  fail "PROVIDER_STATE_INVALID"
record_candidate_active_file "$active_runtime" runtime
validate_configuration_boundary "$state/config.env.production"
updater_started=true
PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
  timeout 60s "$update_script" "$image" "$revision" "$version" >/dev/null 2>&1 ||
  fail "PROVIDER_STATE_INVALID"
cmp -s "$root/.env.production" "$state/config.env.target" ||
  fail "PROVIDER_STATE_INVALID"
printf '%s\n' "$(configuration_file_identity "$root/.env.production")" \
  >"$state/config.env.target.identity"
chmod 600 "$state/config.env.target.identity"
validate_configuration_boundary "$state/config.env.target"
updater_completed=true
compose_up -d --no-deps --no-build --pull never --force-recreate \
  --wait --wait-timeout 180 backend >/dev/null
candidate_container=$(compose ps -q backend)
candidate_inspect=$(docker_container_inspect "$candidate_container" 2>/dev/null) ||
  fail "RECOVERY_REQUIRED"
target_hash=$(docker_container_inspect "$candidate_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "RECOVERY_REQUIRED"
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || fail "candidate runtime hash unavailable"
write_provider_marker verifying "$durable_disposition"
printf '[%s,%s]' "$previous_inspect" "$candidate_inspect" |
  timeout 30s python3 "$provider_helper" verify \
    --run-key "$run_key" --state-root "$state_root" --phase candidate >/dev/null ||
  fail "PROVIDER_STATE_INVALID"
runtime_invariants_bounded "$target_id" "$revision" "$version" "$target_hash" \
  >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"
verify_public_contract "$public_url"
run_safety_hook candidate "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
echo "candidate=ready image_id=$target_id version=$version revision=$revision"

if [ "$mode" = rollback-drill ]; then
  echo "rollback_drill=triggered"
  exit 86
fi

run_safety_hook final "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
validate_configuration_boundary "$state/config.env.target"
provider_finish committed "$candidate_inspect"
mutation_started=false
rollback_complete=true
echo "deployment=completed image_id=$target_id version=$version revision=$revision"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  provider_release_main "$@"
fi
